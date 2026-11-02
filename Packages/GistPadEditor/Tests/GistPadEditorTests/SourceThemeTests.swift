#if canImport(UIKit)
  import Foundation
  import Testing
  import UIKit

  @testable import GistPadEditor

  @Suite(.serialized)
  @MainActor
  struct SourceThemeTests {
    @Test func syntaxUsesSystemInksAndNativeFontsWithoutChangingSourceOrSelection() throws {
      let source =
        """
        ---
        title: Note
        ---
        # Heading
        Plain prose [link](https://example.com)
        > Quoted _emphasis_ and **strong** with ***both***
        > 2) Quoted list item
        **outer _inner_**
        14. Numbered item
        <span>HTML</span> and ~~deleted~~
        `code **literal** [code link](url) ~~not struck~~`
        - Bullet
          * Nested bullet
        + Another bullet
        - [ ] Open
        - [x] Done
        """
      for size in [UIContentSizeCategory.large, .accessibilityExtraLarge] {
        for appearance in [UIUserInterfaceStyle.light, .dark] {
          for contrast in [UIAccessibilityContrast.normal, .high] {
            let session = DocumentSession(documentID: "theme", text: source)
            session.setShowsFrontMatter(true)
            let view = session.textView
            view.traitOverrides.preferredContentSizeCategory = size
            view.traitOverrides.userInterfaceStyle = appearance
            view.traitOverrides.accessibilityContrast = contrast
            view.traitOverrides.legibilityWeight = .regular
            let selection = NSRange(location: 4, length: 3)
            view.selectedRange = selection
            session.highlight()
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
            let inks: [(UIColor, [String])] = [
              (.label, ["# Heading", "Plain", "**outer", "Bullet", "Numbered", "code", "title"]),
              (
                .secondaryLabel,
                [
                  "> Quoted", "2)", "14.", "- Bullet", "* Nested", "+ Another", "<span>", "</span>",
                  "[ ]", "[x]",
                ]
              ),
              (.link, ["[link]", "https://example.com"]),
            ]
            for (ink, texts) in inks {
              for text in texts {
                let actual = try #require(attributes(text)[.foregroundColor] as? UIColor)
                #expect(actual.resolvedColor(with: traits).isEqual(ink.resolvedColor(with: traits)))
              }
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
              #expect(!font.fontDescriptor.symbolicTraits.contains(.traitBold))
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
  }
#endif
