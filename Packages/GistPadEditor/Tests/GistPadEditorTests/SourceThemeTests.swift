#if canImport(UIKit)
  import Foundation
  import GistPadInterface
  import Testing
  import UIKit

  @testable import GistPadEditor

  @Suite(.serialized)
  @MainActor
  struct SourceThemeTests {
    @Test func webTokenRolesPreserveNativeFontsSourceSelectionAndGeneration() throws {
      let source =
        """
        ---
        title: Note
        ---
        # Heading
        Plain prose [link](https://example.com)
        > Quoted _emphasis_ and **strong** with ***both***
        **outer _inner_**
        14. Numbered item
        <span>HTML</span> and ~~deleted~~
        `code **literal** [code link](url) ~~not struck~~`
        - [ ] Open
        - [x] Done
        """
      for size in [UIContentSizeCategory.large, .accessibilityExtraLarge] {
        for appearance in [UIUserInterfaceStyle.light, .dark] {
          for contrast in [UIAccessibilityContrast.normal, .high] {
            let session = DocumentSession(documentID: "theme", text: source)
            let view = session.textView
            view.traitOverrides.preferredContentSizeCategory = size
            view.traitOverrides.userInterfaceStyle = appearance
            view.traitOverrides.accessibilityContrast = contrast
            view.traitOverrides.legibilityWeight = .regular
            let selection = NSRange(location: 4, length: 3)
            view.selectedRange = selection
            session.updateAppearanceIfNeeded()
            let traits = view.traitCollection
            let bodySize = UIFont.preferredFont(
              forTextStyle: .body, compatibleWith: traits
            ).pointSize
            func attributes(_ text: String) -> [NSAttributedString.Key: Any] {
              view.textStorage.attributes(
                at: (source as NSString).range(of: text).location, effectiveRange: nil)
            }
            let heading = try #require(attributes("Heading")[.font] as? UIFont)
            let code = try #require(attributes("code")[.font] as? UIFont)
            let metadata = try #require(attributes("title")[.font] as? UIFont)
            #expect(heading.pointSize == bodySize)
            let headingTraits = try #require(
              heading.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any])
            let weight = try #require(headingTraits[.weight] as? NSNumber)
            #expect(abs(weight.doubleValue - Double(UIFont.Weight.bold.rawValue)) < 0.001)
            #expect(code.pointSize == bodySize)
            #expect(metadata.pointSize == bodySize)
            #expect(code.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
            #expect(metadata.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
            for (text, expected) in [
              ("# Heading", SourceSyntaxColor.emphasis),
              ("Plain", UIColor(InterfaceTheme.text)),
              ("[link]", SourceSyntaxColor.link),
              ("https://example.com", SourceSyntaxColor.destination),
              ("> Quoted", SourceSyntaxColor.quote),
              ("_emphasis_", SourceSyntaxColor.emphasis),
              ("**strong**", SourceSyntaxColor.emphasis),
              ("14.", SourceSyntaxColor.orderedMarker),
              ("Numbered", UIColor(InterfaceTheme.text)),
              ("<span>", SourceSyntaxColor.htmlTag),
              ("</span>", SourceSyntaxColor.htmlTag),
              ("code", UIColor(InterfaceTheme.text)),
              ("title", UIColor(InterfaceTheme.text)),
              ("- [ ]", UIColor(InterfaceTheme.text)),
              ("[ ]", UIColor(InterfaceTheme.accent)),
              ("[x]", UIColor(InterfaceTheme.syntaxMuted)),
            ] {
              let actual = try #require(attributes(text)[.foregroundColor] as? UIColor)
              #expect(
                actual.resolvedColor(with: traits).isEqual(expected.resolvedColor(with: traits)))
            }
            for text in ["strong", "outer", "inner", "both"] {
              let font = try #require(attributes(text)[.font] as? UIFont)
              #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
            }
            for text in ["emphasis", "inner", "both"] {
              let font = try #require(attributes(text)[.font] as? UIFont)
              #expect(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
            }
            #expect(attributes("link")[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
            #expect(
              attributes("https://example.com")[.underlineStyle] as? Int
                == NSUnderlineStyle.single.rawValue)
            #expect(
              attributes("deleted")[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue
            )
            for text in ["literal", "code link", "not struck"] {
              let font = try #require(attributes(text)[.font] as? UIFont)
              #expect(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
              #expect(!font.fontDescriptor.symbolicTraits.contains(.traitItalic))
              #expect((attributes(text)[.underlineStyle] as? Int ?? 0) == 0)
              #expect((attributes(text)[.strikethroughStyle] as? Int ?? 0) == 0)
            }
            #expect(view.text.utf8.elementsEqual(source.utf8))
            #expect(view.selectedRange == selection)
            #expect(session.generation == 0)
          }
        }
      }
    }

    @Test func dynamicTokensResolveTheExactFourAppearancePaletteWithAAContrast() throws {
      let roles: [(UIColor, [UInt32])] = [
        (SourceSyntaxColor.emphasis, [0x1E293B, 0xD2A8FF, 0x0F172A, 0xE6CCFF]),
        (SourceSyntaxColor.quote, [0x22863A, 0x7EE787, 0x155D27, 0xB0F5B7]),
        (SourceSyntaxColor.htmlTag, [0x116329, 0x7EE787, 0x0B4B1E, 0xB0F5B7]),
        (SourceSyntaxColor.destination, [0x032F62, 0xA5D6FF, 0x02234A, 0xD1ECFF]),
        (SourceSyntaxColor.orderedMarker, [0x005CC5, 0x79C0FF, 0x004A9F, 0xB5DDFF]),
      ]
      let appearances: [(UIUserInterfaceStyle, UIAccessibilityContrast)] = [
        (.light, .normal), (.dark, .normal), (.light, .high), (.dark, .high),
      ]
      for (index, appearance) in appearances.enumerated() {
        let traits = UITraitCollection(traitsFrom: [
          .init(userInterfaceStyle: appearance.0), .init(accessibilityContrast: appearance.1),
        ])
        let background = try components(UIColor.systemBackground.resolvedColor(with: traits))
        for (color, expected) in roles {
          let rgb = try components(color.resolvedColor(with: traits))
          #expect(abs(rgb[0] - Double((expected[index] >> 16) & 255) / 255) < 0.001)
          #expect(abs(rgb[1] - Double((expected[index] >> 8) & 255) / 255) < 0.001)
          #expect(abs(rgb[2] - Double(expected[index] & 255) / 255) < 0.001)
          let brighter = max(luminance(rgb), luminance(background))
          let darker = min(luminance(rgb), luminance(background))
          #expect((brighter + 0.05) / (darker + 0.05) >= 4.5)
        }
      }
    }

    @Test func appearanceChangesKeepTheSameAttributedTokensAndNativeUndo() throws {
      let session = DocumentSession(documentID: "dynamic", text: "# Heading\n**bold**")
      let view = session.textView
      view.traitOverrides.legibilityWeight = .regular
      session.updateAppearanceIfNeeded()
      let color = try #require(
        view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
      let identity = session.viewIdentity
      let selection = NSRange(location: 2, length: 4)
      view.selectedRange = selection
      for appearance in [UIUserInterfaceStyle.dark, .light] {
        for contrast in [UIAccessibilityContrast.high, .normal] {
          view.traitOverrides.userInterfaceStyle = appearance
          view.traitOverrides.accessibilityContrast = contrast
          session.updateAppearanceIfNeeded()
          let retained = try #require(
            view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
          #expect(retained === color)
          #expect(session.viewIdentity == identity)
          #expect(view.selectedRange == selection)
          #expect(session.generation == 0)
          #expect(session.text == "# Heading\n**bold**")
          #expect(view.undoManager?.canUndo != true)
        }
      }
    }

    private func components(_ color: UIColor) throws -> [Double] {
      var red: CGFloat = 0
      var green: CGFloat = 0
      var blue: CGFloat = 0
      var alpha: CGFloat = 0
      try #require(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
      return [Double(red), Double(green), Double(blue)]
    }

    private func luminance(_ rgb: [Double]) -> Double {
      let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
      return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
  }
#endif
