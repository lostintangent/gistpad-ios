import Foundation

/// One change to a note's source, with UTF-16 offsets. It applies only to the exact text of the
/// document it was made from.
public struct MarkdownEdit: Sendable {
    public let document: MarkdownDocument
    public let range: NSRange
    public let replacement: String
    /// The selection after the edit, or nil to keep the caret where it was.
    public let selection: NSRange?

    init(document: MarkdownDocument, range: NSRange, replacement: String, selection: NSRange?) {
        self.document = document
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// Replacements are ordered, nonoverlapping UTF-16 ranges in the document, inside `range`.
    init(
        document: MarkdownDocument, range: NSRange, replacements: [(range: NSRange, replacement: String)],
        selection: NSRange
    ) {
        var start = selection.location
        var end = NSMaxRange(selection)
        var delta = 0
        for replacement in replacements {
            let current = NSRange(
                location: replacement.range.location + delta, length: replacement.range.length)
            let length = replacement.replacement.utf16.count
            start = Self.remap(start, through: current, replacementLength: length)
            end = Self.remap(end, through: current, replacementLength: length)
            delta += length - replacement.range.length
        }
        let result = NSMutableString(string: document.source.substring(with: range))
        for replacement in replacements.reversed() {
            result.replaceCharacters(
                in: NSRange(
                    location: replacement.range.location - range.location, length: replacement.range.length),
                with: replacement.replacement)
        }
        self.init(
            document: document, range: range, replacement: result as String,
            selection: NSRange(location: start, length: end - start))
    }

    /// The document's text with the change made.
    public var result: String {
        document.source.replacingCharacters(in: range, with: replacement)
    }

    private static func remap(_ offset: Int, through range: NSRange, replacementLength: Int) -> Int {
        if offset < range.location { return offset }
        if offset >= NSMaxRange(range) { return offset + replacementLength - range.length }
        return range.location + min(offset - range.location, replacementLength)
    }

    public enum Failure: Error, Equatable {
        /// The keyboard is composing or Writing Tools is working, so the editor isn't settled.
        case unsettled
        /// The text changed since the edit was made, so it no longer fits.
        case changed
        case invalidLink
    }
}

extension MarkdownEdit.Failure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsettled:
            String(localized: "Finish typing or wait for Writing Tools, then try again.", bundle: .module)
        case .changed:
            String(localized: "This file changed. Select the text again.", bundle: .module)
        case .invalidLink:
            String(localized: "Enter a complete web, email or phone link.", bundle: .module)
        }
    }
}
