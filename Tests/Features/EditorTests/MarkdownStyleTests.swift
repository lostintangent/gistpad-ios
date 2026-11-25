#if canImport(UIKit)
    import Foundation
    import Testing
    import UIKit

    @testable import Editor

    @Suite(.serialized)
    struct MarkdownStyleTests {
        @Test func syntaxUsesTheWebsInksAndNativeFontsWithoutChangingSourceOrSelection() throws {
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
                ```toc
                fenced line
                ```
                """
            for size in [UIContentSizeCategory.large, .accessibilityExtraLarge] {
                for appearance in [UIUserInterfaceStyle.light, .dark] {
                    for contrast in [UIAccessibilityContrast.normal, .high] {
                        let editor = MarkdownEditor(text: source)
                        editor.setShowsFrontMatter(true)
                        let view = editor.textView
                        view.traitOverrides.preferredContentSizeCategory = size
                        view.traitOverrides.userInterfaceStyle = appearance
                        view.traitOverrides.accessibilityContrast = contrast
                        view.traitOverrides.legibilityWeight = .regular
                        view.updateTraitsIfNeeded()
                        let selection = NSRange(location: 4, length: 3)
                        view.selectedRange = selection
                        editor.highlight()
                        let traits = view.traitCollection
                        #expect(traits.preferredContentSizeCategory == size)
                        #expect(traits.userInterfaceStyle == appearance)
                        #expect(traits.accessibilityContrast == contrast)
                        let bodySize = UIFont.preferredFont(
                            forTextStyle: .body, compatibleWith: traits
                        ).pointSize
                        func attributes(
                            _ text: String, options: NSString.CompareOptions = []
                        ) -> [NSAttributedString.Key: Any] {
                            view.textStorage.attributes(
                                at: (source as NSString).range(of: text, options: options).location,
                                effectiveRange: nil)
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
                        // gistpad.dev's GitHub palette, markers included, where nil is the text ink. List
                        // and task markers and fences are markup, and the text they introduce is content.
                        func web(
                            _ light: UInt32?, _ dark: UInt32?, highContrast highLight: UInt32?,
                            _ highDark: UInt32?
                        ) -> UIColor {
                            let high = contrast == .high
                            guard let hex = appearance == .dark ? (high ? highDark : dark) : (high ? highLight : light)
                            else { return .label }
                            return UIColor(
                                red: CGFloat(hex >> 16) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
                        }
                        let inks: [(UIColor, [String])] = [
                            (.label, ["Plain", "HTML", "Bullet", "Numbered", "code", "title", "fenced line"]),
                            (
                                web(nil, 0xD2A8FF, highContrast: nil, 0xE6CCFF),
                                ["# Heading", "Heading", "_emphasis", "**strong", "***both", "**outer", "_inner"]
                            ),
                            (web(0x22863A, 0x7EE787, highContrast: 0x155D27, 0xB0F5B7), ["> Quoted", "> 2)"]),
                            (web(0x116329, 0x7EE787, highContrast: 0x0B4B1E, 0xB0F5B7), ["<span>", "</span>"]),
                            (web(0x032F62, 0xA5D6FF, highContrast: 0x02234A, 0xD1ECFF), ["https://example.com"]),
                            (web(0x032F62, nil, highContrast: 0x02234A, nil), ["[link]"]),
                            (
                                .secondaryLabel,
                                ["2)", "14.", "- Bullet", "* Nested", "+ Another", "[ ]", "[x]", "```toc"]
                            ),
                        ]
                        for (ink, texts) in inks {
                            for text in texts {
                                let actual = try #require(attributes(text)[.foregroundColor] as? UIColor)
                                #expect(actual.resolvedColor(with: traits).isEqual(ink.resolvedColor(with: traits)))
                            }
                        }
                        let closingFence = try #require(
                            attributes("```", options: .backwards)[.foregroundColor] as? UIColor)
                        #expect(
                            closingFence.resolvedColor(with: traits).isEqual(
                                UIColor.secondaryLabel.resolvedColor(with: traits)))
                        let headingMarker = try #require(attributes("# Heading")[.font] as? UIFont)
                        #expect(headingMarker.fontDescriptor.symbolicTraits.contains(.traitBold))
                        for text in ["```toc", "fenced line"] {
                            let font = try #require(attributes(text)[.font] as? UIFont)
                            #expect(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
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
                        #expect(editor.generation == 0)
                    }
                }
            }
        }

        @Test func aKeystrokeHighlightsTheNoteOnce() {
            let editor = MarkdownEditor(text: "# Heading\n\nProse")
            let view = editor.textView
            view.selectedRange = NSRange(location: view.textStorage.length, length: 0)
            let passes = AttributePasses(of: view.textStorage)
            view.insertText("!")
            #expect(editor.document.text == "# Heading\n\nProse!")
            #expect(passes.ranges.count == 1)
        }

        @Test func aKeystrokeHighlightsOnlyItsParagraph() {
            let paragraph = "Some **bold** prose.\n\n"
            let editor = MarkdownEditor(text: String(repeating: paragraph, count: 100))
            let view = editor.textView
            let start = 50 * paragraph.utf16.count
            view.selectedRange = NSRange(location: start + 5, length: 0)
            let passes = AttributePasses(of: view.textStorage)
            view.insertText("x")
            #expect(passes.ranges == [(view.text as NSString).lineRange(for: NSRange(location: start, length: 0))])
        }

        @Test func highlightingEditsLooksLikeOpeningTheNoteAfresh() {
            let editor = MarkdownEditor(text: "# Notes\n\nProse with `code\n\n```\nfenced\n```\nTail **bold**\n")
            let view = editor.textView
            // Opening a fence above another turns the code below it into prose, and back.
            view.selectedRange = NSRange(location: 9, length: 0)
            view.insertText("```\n")
            view.selectedRange = NSRange(location: 9, length: 4)
            view.deleteBackward()
            view.selectedRange = NSRange(location: 25, length: 0)
            view.insertText("` and **more")
            view.selectedRange = NSRange(location: 0, length: view.textStorage.length)
            view.insertText(view.text.replacingOccurrences(of: "Tail", with: "> Tail"))
            #expect(view.textStorage.isEqual(to: MarkdownEditor(text: view.text).textView.textStorage))
        }
    }

    /// The ranges of the passes that change `storage`'s attributes without changing its characters.
    private final class AttributePasses: NSObject {
        private(set) var ranges: [NSRange] = []

        init(of storage: NSTextStorage) {
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(didProcessEditing(_:)),
                name: NSTextStorage.didProcessEditingNotification, object: storage)
        }

        @objc private func didProcessEditing(_ notification: Notification) {
            guard let storage = notification.object as? NSTextStorage, storage.editedMask == .editedAttributes
            else { return }
            ranges.append(storage.editedRange)
        }
    }
#endif
