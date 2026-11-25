import Foundation
import Markdown

/// The model's revised note, compared line by line with the part of the note it read. Each run of
/// changed lines becomes one change, so the review shows exactly what the model changed.
extension Proposal.Change {
    /// The text this change only adds, when it leaves everything it quotes in place.
    var insertedText: String? {
        let original = Array(quote)
        let revised = Array(replacement)
        let prefix = zip(original, revised).prefix { $0.0 == $0.1 }.count
        let suffix = zip(original.dropFirst(prefix).reversed(), revised.dropFirst(prefix).reversed())
            .prefix { $0.0 == $0.1 }.count
        guard prefix + suffix == original.count, prefix + suffix < revised.count else { return nil }
        let insertion = String(revised[prefix..<(revised.count - suffix)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return insertion.isEmpty ? nil : insertion
    }

    static func lineChanges(
        in source: String, visible: NSRange, revised: String
    ) throws -> [(Self, NSRange)] {
        let newline = source.contains("\r\n") ? "\r\n" : "\n"
        let old = lines(in: source, visible: visible)
        var new = unwrapped(revised, note: old.map(\.text)).components(separatedBy: "\n")
        while new.first?.allSatisfy(\.isWhitespace) == true { new.removeFirst() }
        while new.last?.allSatisfy(\.isWhitespace) == true { new.removeLast() }
        // Platform gap: the model adds blank lines between the items of a tight list. Remove when an
        // on-device model keeps a tight list tight.
        if !hasLooseList(old.map(\.text)) { new = tightened(new) }
        // An unclosed fence would turn the rest of the note into code.
        guard !new.isEmpty, hasOpenFence(new) == hasOpenFence(old.map(\.text)) else {
            throw IntelligenceError.unsafeEdit
        }
        guard !old.isEmpty else {
            let text = source as NSString
            let needsBreak =
                visible.location > 0
                && !CharacterSet.newlines.contains(
                    Unicode.Scalar(text.character(at: visible.location - 1)) ?? " ")
            return [
                (
                    Self(
                        quote: "",
                        replacement: (needsBreak ? newline : "") + new.joined(separator: newline) + newline,
                        reason: ""),
                    NSRange(location: visible.location, length: 0)
                )
            ]
        }
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.map(key).difference(from: old.map { key($0.text) }) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // The lines the model copied, paired in order between a pair before the note and one after it.
        let copied: [(old: Int, new: Int)] =
            [(-1, -1)]
            + zip(old.indices.filter { !removed.contains($0) }, new.indices.filter { !inserted.contains($0) })
            .map { ($0, $1) } + [(old.count, new.count)]
        // A copied line keeps its original text, including what the key ignores.
        for (i, j) in copied.dropFirst().dropLast() { new[j] = old[i].text }
        // A change replaces the lines between two pairs.
        func covered(by change: (start: Int, end: Int)) -> (old: Range<Int>, new: Range<Int>) {
            let (start, end) = (copied[change.start], copied[change.end])
            return (start.old + 1..<end.old, start.new + 1..<end.new)
        }
        // A quote needs existing text and a replacement needs a line to keep its line breaks.
        func quotesText(_ change: (start: Int, end: Int)) -> Bool {
            let lines = covered(by: change)
            return !lines.new.isEmpty && old[lines.old].contains { !$0.text.allSatisfy(\.isWhitespace) }
        }
        var changes: [(start: Int, end: Int)] = []
        for end in copied.indices.dropFirst() where end > changes.last?.end ?? 0 {
            var change = (start: end - 1, end: end)
            let lines = covered(by: change)
            guard !lines.old.isEmpty || !lines.new.isEmpty else { continue }
            // A change takes in the copied lines before it, or after it at the top, and any change it
            // reaches, until it quotes text.
            while !quotesText(change), change.start > 0 || change.end < copied.count - 1 {
                if change.start > 0 { change.start -= 1 } else { change.end += 1 }
                if let last = changes.last, change.start < last.end { change.start = changes.removeLast().start }
            }
            changes.append(change)
        }
        return changes.map { change in
            let lines = covered(by: change)
            let range = NSUnionRange(old[lines.old.lowerBound].range, old[lines.old.upperBound - 1].range)
            return (
                Self(
                    quote: (source as NSString).substring(with: range),
                    replacement: new[lines.new].joined(separator: newline), reason: ""),
                range
            )
        }
    }

    // Platform gap: the model drops trailing spaces, respaces words and curls quotes in lines it
    // copies, so the diff ignores them. Remove when an on-device model copies lines exactly.
    private static func key(_ line: String) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let words = line.dropFirst(indent.count).split(whereSeparator: { $0 == " " || $0 == "\t" })
        return (indent + words.joined(separator: " "))
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    private static func isListItem(_ line: String) -> Bool {
        MarkdownDocument(line).isListItem(at: 0)
    }

    /// Whether the note separates any two list items with a blank line.
    private static func hasLooseList(_ lines: [String]) -> Bool {
        lines.indices.contains { index in
            index > 0 && lines[index].allSatisfy(\.isWhitespace) && isListItem(lines[index - 1])
                && lines[index...].first { !$0.allSatisfy(\.isWhitespace) }.map(isListItem) == true
        }
    }

    /// The lines without blank lines between list items, so a tight list stays tight.
    private static func tightened(_ lines: [String]) -> [String] {
        lines.indices.compactMap { index in
            let line = lines[index]
            guard line.allSatisfy(\.isWhitespace),
                lines[..<index].last(where: { !$0.allSatisfy(\.isWhitespace) }).map(isListItem) == true,
                lines[index...].first(where: { !$0.allSatisfy(\.isWhitespace) }).map(isListItem) == true
            else { return line }
            return nil
        }
    }

    private static func hasOpenFence(_ lines: [String]) -> Bool {
        // A leading line break keeps a first `---` line from reading as front matter.
        MarkdownDocument("\n" + lines.joined(separator: "\n")).literals.contains { $0.kind == .code && !$0.isClosed }
    }

    /// The visible lines without their line breaks, leaving out trailing blank lines.
    private static func lines(in source: String, visible: NSRange) -> [(text: String, range: NSRange)]
    {
        let text = source as NSString
        var lines: [(text: String, range: NSRange)] = []
        var location = visible.location
        let end = NSMaxRange(visible)
        while location < end {
            var lineEnd = location
            while lineEnd < end, text.character(at: lineEnd) != 0x0A { lineEnd += 1 }
            var contentEnd = lineEnd
            if contentEnd > location, text.character(at: contentEnd - 1) == 0x0D { contentEnd -= 1 }
            let range = NSRange(location: location, length: contentEnd - location)
            lines.append((text.substring(with: range), range))
            location = lineEnd + 1
        }
        while lines.last?.text.allSatisfy(\.isWhitespace) == true { lines.removeLast() }
        return lines
    }

    // Platform gap: the model sometimes echoes a multiline note as the escaped JSON string it read,
    // or fences its whole reply. Remove when an on-device model returns the note as plain Markdown.
    private static func unwrapped(_ text: String, note: [String]) -> String {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n")
        if note.count > 1, !text.contains("\n"), text.contains(#"\n"#) {
            var body = Substring(text.trimmingCharacters(in: .whitespaces))
            if body.hasPrefix(#"{"note":""#) { body = body.dropFirst(9) }
            if body.hasSuffix(#""}"#) { body = body.dropLast(2) }
            if let decoded = try? JSONDecoder().decode(String.self, from: Data(#""\#(body)""#.utf8)) {
                text = decoded
            }
        }
        if note.first?.hasPrefix("```") != true,
            let fenced = text.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(
                of: #/```(?:markdown|md)?[ \t]*\n([\s\S]*?)\n?```/#)
        {
            return String(fenced.1)
        }
        return text
    }
}
