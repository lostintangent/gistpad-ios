#if canImport(UIKit)
    import Markdown
    import UIKit

    /// How Markdown source looks: native fonts for the view's traits, in gistpad.dev's GitHub palette.
    struct MarkdownStyle {
        private let body: UIFont
        private let heading: UIFont
        private let code: UIFont

        init(traits: UITraitCollection) {
            body = .preferredFont(forTextStyle: .body, compatibleWith: traits)
            heading = .systemFont(ofSize: body.pointSize, weight: .bold)
            code = .monospacedSystemFont(
                ofSize: body.pointSize, weight: traits.legibilityWeight == .bold ? .semibold : .regular)
        }

        /// Plain text, which is also what typing continues with.
        var typingAttributes: [NSAttributedString.Key: Any] {
            [.font: body, .foregroundColor: UIColor.label]
        }

        /// Styles all of `storage`, which holds `document`.
        func paint(_ document: MarkdownDocument, in storage: NSTextStorage) {
            storage.setAttributes(typingAttributes, range: NSRange(location: 0, length: storage.length))
            for span in document.spans {
                storage.addAttributes(attributes(for: span.kind), range: span.range)
                if span.kind == .strong || span.kind == .emphasis {
                    let addedTrait: UIFontDescriptor.SymbolicTraits =
                        span.kind == .strong ? .traitBold : .traitItalic
                    storage.enumerateAttribute(.font, in: span.range) { value, range, _ in
                        guard let font = value as? UIFont,
                            let descriptor = font.fontDescriptor.withSymbolicTraits(
                                font.fontDescriptor.symbolicTraits.union(addedTrait))
                        else { preconditionFailure("The system source font must support Markdown emphasis.") }
                        storage.addAttribute(
                            .font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: range)
                    }
                }
            }
        }

        private func attributes(for kind: MarkdownDocument.Span.Kind) -> [NSAttributedString.Key: Any] {
            switch kind {
            case .heading:
                [.foregroundColor: Self.headingInk, .font: heading]
            case .strong, .emphasis:
                [.foregroundColor: Self.headingInk]
            case .blockquote:
                [.foregroundColor: Self.quoteInk]
            case .htmlTag:
                [.foregroundColor: Self.htmlTagInk]
            case .orderedMarker, .punctuation, .task, .checkedTask:
                [.foregroundColor: UIColor.secondaryLabel]
            case .strikethrough:
                [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
            case .code:
                [.foregroundColor: UIColor.label, .font: code, .underlineStyle: 0, .strikethroughStyle: 0]
            case .frontMatter:
                [.foregroundColor: UIColor.label, .font: code]
            case .link, .linkDestination:
                [
                    .foregroundColor: kind == .link ? Self.linkLabelInk : Self.urlInk,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
            }
        }

        // gistpad.dev's GitHub palette in Light, Dark, and each with Increase Contrast. Where the
        // web uses its text ink, nil keeps `label`: Light headings, bold and italic, and Dark link labels.
        private static let headingInk = ink(nil, 0xD2A8FF, highContrast: nil, 0xE6CCFF)
        private static let quoteInk = ink(0x22863A, 0x7EE787, highContrast: 0x155D27, 0xB0F5B7)
        private static let htmlTagInk = ink(0x116329, 0x7EE787, highContrast: 0x0B4B1E, 0xB0F5B7)
        private static let urlInk = ink(0x032F62, 0xA5D6FF, highContrast: 0x02234A, 0xD1ECFF)
        private static let linkLabelInk = ink(0x032F62, nil, highContrast: 0x02234A, nil)

        private static func ink(
            _ light: UInt32?, _ dark: UInt32?, highContrast highLight: UInt32?, _ highDark: UInt32?
        ) -> UIColor {
            UIColor { traits in
                let high = traits.accessibilityContrast == .high
                let hex =
                    traits.userInterfaceStyle == .dark ? (high ? highDark : dark) : (high ? highLight : light)
                guard let hex else { return .label.resolvedColor(with: traits) }
                return UIColor(
                    red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            }
        }
    }
#endif
