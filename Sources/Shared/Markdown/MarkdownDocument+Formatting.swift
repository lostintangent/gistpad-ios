import Foundation

extension MarkdownDocument {
    /// Wraps the selection in `**`, or unwraps it when it's already bold.
    public func edit(bolding selection: NSRange) -> MarkdownEdit {
        wrapping(selection, in: "**")
    }

    /// Wraps the selection in `*`, or unwraps it when it's already italic.
    public func edit(italicizing selection: NSRange) -> MarkdownEdit {
        wrapping(selection, in: "*")
    }

    /// Wraps the selection in backticks, or unwraps code it holds or sits in.
    public func edit(coding selection: NSRange) -> MarkdownEdit {
        let selected = source.substring(with: selection)
        if let edit = unwrappingCode(selection, selected: selected) { return edit }
        let delimiter = String(repeating: "`", count: Self.longestBacktickRun(in: selected) + 1)
        let padded =
            selected.hasPrefix("`") || selected.hasSuffix("`")
            || (selected.hasPrefix(" ") && selected.hasSuffix(" ") && !selected.allSatisfy(\.isWhitespace))
        let padding = padded ? " " : ""
        return edit(
            replacing: selection, with: delimiter + padding + selected + padding + delimiter,
            selection: NSRange(
                location: selection.location + delimiter.utf16.count + padding.utf16.count,
                length: selection.length))
    }

    /// Fences the selected lines as a code block.
    public func edit(fencing selection: NSRange) -> MarkdownEdit {
        let block = source.lineRange(covering: selection)
        let content = source.substring(with: block)
        let fence = String(repeating: "`", count: max(3, Self.longestBacktickRun(in: content) + 1))
        let endsLine = content.utf16.last == 10 || content.utf16.last == 13
        let opening = fence + lineBreak
        return edit(
            replacing: block,
            with: opening + content + (endsLine ? "" : lineBreak) + fence + (endsLine ? lineBreak : ""),
            selection: NSRange(location: block.location + opening.utf16.count, length: block.length))
    }

    /// Links the selection, labeled with `label` or else the destination. Throws `invalidLink`
    /// unless the destination is a complete web, email or phone link.
    public func edit(linking selection: NSRange, to destination: String, label: String) throws -> MarkdownEdit {
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: destination), let scheme = url.scheme?.lowercased(),
            ["http", "https", "mailto", "tel"].contains(scheme),
            destination.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r<>")) == nil,
            label.rangeOfCharacter(from: .newlines) == nil,
            !["http", "https"].contains(scheme) || !(url.host ?? "").isEmpty,
            !["mailto", "tel"].contains(scheme) || !url.path.isEmpty
        else { throw MarkdownEdit.Failure.invalidLink }
        let target = url.absoluteString
        let escaped = target.contains("(") || target.contains(")") ? "<\(target)>" : target
        let title = (label.isEmpty ? target : label)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let link = "[\(title)](\(escaped))"
        return edit(
            replacing: selection, with: link,
            selection: NSRange(location: selection.location + link.utf16.count, length: 0))
    }

    /// Makes the selected lines headings at `level`, or body text at 0. Lines already at
    /// `level` become body text. Nil when nothing changes.
    public func edit(heading level: Int, over selection: NSRange) -> MarkdownEdit? {
        togglingLines(selection) { line, _ in
            let heading = Self.headingMarker.firstMatch(in: text, options: .anchored, range: line.contents)
            let closing = heading.flatMap {
                let end = NSMaxRange($0.range(at: 1))
                return Self.headingClosing.firstMatch(
                    in: text, range: NSRange(location: end, length: line.contentsEnd - end))?.range
            }
            return (
                heading.map { NSMaxRange($0.range(at: 1)) },
                level == 0 ? "" : String(repeating: "#", count: level) + " ",
                (heading?.range(at: 2).length ?? 0) == level, closing
            )
        }
    }

    /// Bullets the selected lines, or unbullets them when they're all bulleted.
    public func edit(bulleting selection: NSRange) -> MarkdownEdit? {
        togglingLines(selection) { line, _ in
            let item = listItem(on: line)
            return (item.map { NSMaxRange($0.prefix) }, "- ", item?.bullet != nil && item?.box == nil, nil)
        }
    }

    /// Numbers the selected lines from 1, or unnumbers them when they're all numbered.
    public func edit(numbering selection: NSRange) -> MarkdownEdit? {
        togglingLines(selection) { line, index in
            let item = listItem(on: line)
            return (item.map { NSMaxRange($0.prefix) }, "\(index + 1). ", item?.number != nil, nil)
        }
    }

    /// Makes the selected lines tasks, keeping any that are done, or plain lines when they're all tasks.
    public func edit(checklisting selection: NSRange) -> MarkdownEdit? {
        togglingLines(selection) { line, _ in
            let item = listItem(on: line)
            return (
                item.map { NSMaxRange($0.prefix) }, item?.isChecked == true ? "- [x] " : "- [ ] ",
                item?.box != nil, nil
            )
        }
    }

    /// Quotes the selected lines, or unquotes them when they're all quoted.
    public func edit(quoting selection: NSRange) -> MarkdownEdit? {
        togglingLines(selection) { line, _ in
            let quote = Self.quoteMarker.firstMatch(in: text, options: .anchored, range: line.contents)
            return (quote.map { NSMaxRange($0.range(at: 1)) }, "> ", quote != nil, nil)
        }
    }

    /// Checks the task box that starts at `location`, or unchecks it. Quoted and numbered tasks
    /// count. Nil unless a box starts exactly there, outside code and front matter.
    public func edit(togglingTaskAt location: Int) -> MarkdownEdit? {
        guard location >= 0, location < source.length,
            let box = listItem(at: location, includingQuoted: true)?.box, box.location == location,
            !isProtected(box)
        else { return nil }
        return edit(replacing: box, with: source.substring(with: box) == "[ ]" ? "[x]" : "[ ]", selection: nil)
    }

    /// One line's toggle: where its marker ends, if it has one, the marker it should have, whether
    /// it already counts as formatted, and any closing to remove.
    private typealias LineFormat = (markerEnd: Int?, marker: String, isFormatted: Bool, closing: NSRange?)

    /// Replaces each selected line's marker, after its indent, or removes them all when every
    /// line is already formatted.
    private func togglingLines(_ selection: NSRange, format: (Line, Int) -> LineFormat) -> MarkdownEdit? {
        let lines = source.lines(in: source.lineRange(covering: selection))
        let formats = lines.enumerated().map { format($0.element, $0.offset) }
        let removing = formats.allSatisfy(\.isFormatted)
        let changes = zip(lines, formats).flatMap { line, format -> [Change] in
            let indent = line.range.location + indentLength(of: line)
            let marker = NSRange(location: indent, length: (format.markerEnd ?? indent) - indent)
            return [(marker, removing ? "" : format.marker)] + (format.closing.map { [($0, "")] } ?? [])
        }
        .filter { source.substring(with: $0.range) != $0.replacement }
        return edit(changes: changes, selection: selection)
    }

    private func wrapping(_ selection: NSRange, in marker: String) -> MarkdownEdit {
        let selected = source.substring(with: selection)
        let count = marker.utf16.count
        let italicSelection =
            marker != "*"
            || (selected.prefix(while: { $0 == "*" }).count % 2 == 1
                && selected.reversed().prefix(while: { $0 == "*" }).count % 2 == 1)
        if selected.utf16.count >= count * 2, selected.hasPrefix(marker), selected.hasSuffix(marker),
            italicSelection
        {
            let content = (selected as NSString).substring(
                with: NSRange(location: count, length: selected.utf16.count - count * 2))
            return edit(
                replacing: selection, with: content,
                selection: NSRange(location: selection.location, length: content.utf16.count))
        }
        let italicSurroundings =
            marker != "*"
            || ((selection.location < 2 || source.character(at: selection.location - 2) != 42)
                && (NSMaxRange(selection) + 1 >= source.length
                    || source.character(at: NSMaxRange(selection) + 1) != 42))
        if selection.location >= count, NSMaxRange(selection) + count <= source.length,
            source.substring(with: NSRange(location: selection.location - count, length: count)) == marker,
            source.substring(with: NSRange(location: NSMaxRange(selection), length: count)) == marker,
            italicSurroundings
        {
            let enclosing = NSRange(location: selection.location - count, length: selection.length + count * 2)
            return edit(
                replacing: enclosing, with: selected,
                selection: NSRange(location: enclosing.location, length: selection.length))
        }
        return edit(
            replacing: selection, with: marker + selected + marker,
            selection: NSRange(location: selection.location + count, length: selection.length))
    }

    /// Unwraps code around the selection, or the code the selection is. Nil when it's neither.
    private func unwrappingCode(_ selection: NSRange, selected: String) -> MarkdownEdit? {
        var opening = selection.location
        var closing = NSMaxRange(selection)
        var padding = 0
        if opening > 1, closing + 1 < source.length,
            source.character(at: opening - 1) == 32, source.character(at: closing) == 32,
            source.character(at: opening - 2) == .backtick, source.character(at: closing + 1) == .backtick
        {
            opening -= 1
            closing += 1
            padding = 1
        }
        while opening > 0, source.character(at: opening - 1) == .backtick { opening -= 1 }
        while closing < source.length, source.character(at: closing) == .backtick { closing += 1 }
        let before = selection.location - opening - padding
        if before > Self.longestBacktickRun(in: selected), closing - NSMaxRange(selection) - padding == before {
            return edit(
                replacing: NSRange(location: opening, length: closing - opening), with: selected,
                selection: NSRange(location: opening, length: selection.length))
        }
        let ticks = selected.prefix { $0 == "`" }.count
        guard ticks > 0, selected.reversed().prefix(while: { $0 == "`" }).count == ticks,
            selected.utf16.count >= ticks * 2
        else { return nil }
        var content = String(selected.dropFirst(ticks).dropLast(ticks))
        guard Self.longestBacktickRun(in: content) < ticks else { return nil }
        if content.hasPrefix(" "), content.hasSuffix(" "), !content.allSatisfy(\.isWhitespace) {
            content = String(content.dropFirst().dropLast())
        }
        return edit(
            replacing: selection, with: content,
            selection: NSRange(location: selection.location, length: content.utf16.count))
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}
