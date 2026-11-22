import Foundation

/// One change to a note's source, with UTF-16 offsets.
public struct Edit: Sendable {
    public let range: NSRange
    public let expected: String
    public let replacement: String
    /// The selection after the edit, or nil to keep the caret where it was.
    public let selection: NSRange?

    public init(range: NSRange, expected: String, replacement: String, selection: NSRange? = nil) {
        self.range = range
        self.expected = expected
        self.replacement = replacement
        self.selection = selection
    }

    /// Replacements are ordered, nonoverlapping UTF-16 ranges in the original source.
    init(
        range: NSRange, expected: String, replacements: [(range: NSRange, replacement: String)],
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
        let result = NSMutableString(string: expected)
        for replacement in replacements.reversed() {
            result.replaceCharacters(
                in: NSRange(
                    location: replacement.range.location - range.location, length: replacement.range.length),
                with: replacement.replacement)
        }
        self.init(
            range: range, expected: expected, replacement: result as String,
            selection: NSRange(location: start, length: end - start))
    }

    public func applying(to source: String) throws -> String {
        guard try Self.text(in: source, at: range).utf8.elementsEqual(expected.utf8) else {
            throw Failure.changed
        }
        return (source as NSString).replacingCharacters(in: range, with: replacement)
    }

    /// The source at `range`, which must be in bounds and must not split a surrogate pair.
    static func text(in source: String, at range: NSRange) throws -> String {
        let utf16 = source as NSString
        guard range.location >= 0, range.length >= 0, range.location <= utf16.length,
            range.length <= utf16.length - range.location
        else { throw Failure.changed }
        for boundary in [range.location, NSMaxRange(range)]
        where boundary > 0 && boundary < utf16.length {
            guard !(0xD800...0xDBFF).contains(utf16.character(at: boundary - 1))
                || !(0xDC00...0xDFFF).contains(utf16.character(at: boundary))
            else { throw Failure.changed }
        }
        return utf16.substring(with: range)
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

extension Edit.Failure: LocalizedError {
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
