#if canImport(UIKit)
  import GistPadInterface
  import Testing
  import UIKit

  @testable import GistPadEditor

  @Suite(.serialized)
  @MainActor
  struct SourceThemeTests {
    @Test func themeKeepsBodySizedHeadingsMonospacedCodeAndUnchangedSource() throws {
      let source = "---\ntitle: Note\n---\n# Heading\n`code`\n- [ ] Open\n- [x] Done\n"
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
            #expect(abs(weight.doubleValue - Double(UIFont.Weight.semibold.rawValue)) < 0.001)
            #expect(code.pointSize == bodySize)
            #expect(metadata.pointSize == bodySize)
            #expect(code.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
            #expect(metadata.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
            for (text, expected) in [
              ("code", UIColor(InterfaceTheme.syntaxCode)),
              ("title", UIColor(InterfaceTheme.syntaxMuted)),
              ("[ ]", UIColor(InterfaceTheme.accent)),
              ("[x]", UIColor(InterfaceTheme.syntaxMuted)),
            ] {
              let actual = try #require(attributes(text)[.foregroundColor] as? UIColor)
              #expect(
                actual.resolvedColor(with: traits).isEqual(expected.resolvedColor(with: traits)))
            }
            #expect(view.text.utf8.elementsEqual(source.utf8))
            #expect(view.selectedRange == selection)
            #expect(session.generation == 0)
          }
        }
      }
    }
  }
#endif
