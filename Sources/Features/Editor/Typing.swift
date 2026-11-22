import Foundation

enum Typing {
    /// Returns nil for ordinary input or protected syntax so the caller can use native input.
    static func edit(
        in source: String, selection: NSRange, replacement: String
    ) throws -> Edit? {
        let selected = try Edit.text(in: source, at: selection)
        if ["\n", "\r", "\r\n"].contains(replacement) {
            let protected = protectedRanges(in: source)
            guard !isProtected(selection, ranges: protected) else { return nil }
            return continueList(in: source, selection: selection, protected: protected)
        }
        if let edit = pairBracket(in: source, selection: selection, replacement: replacement) {
            return isProtected(selection, ranges: protectedRanges(in: source)) ? nil : edit
        }
        guard !selected.isEmpty, !selected.contains(where: \.isNewline),
            !selected.allSatisfy(\.isWhitespace),
            replacement.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
            let url = URL(string: replacement),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            let host = url.host, !host.isEmpty
        else { return nil }
        guard !isProtected(selection, ranges: protectedRanges(in: source)) else { return nil }
        let label = selected.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let destination = url.absoluteString
            .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
        let markdown = "[\(label)](\(destination))"
        return Edit(
            range: selection, expected: selected, replacement: markdown,
            selection: NSRange(location: selection.location + markdown.utf16.count, length: 0))
    }

    private static let brackets = [
        (open: "(", close: ")"), (open: "[", close: "]"), (open: "{", close: "}"),
    ]
    private static let closesBefore = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ")]}.,;:!?"))

    /// An opener closes before a space, a line end or a closer, so one typed before a word stays
    /// single. Its closer steps over a waiting one, and backspace in an empty pair deletes both.
    private static func pairBracket(in source: String, selection: NSRange, replacement: String)
        -> Edit?
    {
        let text = source as NSString
        let caret = NSMaxRange(selection)
        let next = caret < text.length ? text.substring(with: NSRange(location: caret, length: 1)) : ""
        if replacement.isEmpty, selection.length == 1,
            let pair = brackets.first(where: { $0.open == text.substring(with: selection) }),
            next == pair.close
        {
            return Edit(
                range: NSRange(location: selection.location, length: 2), expected: pair.open + pair.close,
                replacement: "", selection: NSRange(location: selection.location, length: 0))
        }
        guard selection.length == 0 else { return nil }
        if let pair = brackets.first(where: { $0.open == replacement }),
            next.isEmpty || next.rangeOfCharacter(from: closesBefore) != nil
        {
            return Edit(
                range: selection, expected: "", replacement: pair.open + pair.close,
                selection: NSRange(location: caret + 1, length: 0))
        }
        // When the line already balances its closers, the one after the caret is waiting for this one.
        if let pair = brackets.first(where: { $0.close == replacement }), next == pair.close {
            let line = text.substring(with: text.lineRange(for: selection))
            guard line.count(where: { String($0) == pair.open })
                <= line.count(where: { String($0) == pair.close })
            else { return nil }
            return Edit(
                range: selection, expected: "", replacement: "",
                selection: NSRange(location: caret + 1, length: 0))
        }
        return nil
    }

    static func isListItem(in source: String, at offset: Int) -> Bool {
        let text = source as NSString
        guard offset >= 0, offset <= text.length else { return false }
        let location = min(offset, max(0, text.length - 1))
        return listLine(in: text, at: location) != nil
    }

    /// Call only outside composition and Writing Tools. Offsets and returned selection are UTF-16.
    static func indent(
        in source: String, selection: NSRange, outdent: Bool, keeping result: NSRange? = nil
    ) throws -> Edit? {
        _ = try Edit.text(in: source, at: selection)
        let text = source as NSString
        let block = text.lineRange(covering: selection)
        let protected = protectedRanges(in: source)
        let kept = result ?? selection
        guard !isProtected(block, ranges: protected) else { return nil }
        if let nested = nestList(
            in: source, block: block, selection: kept, outdent: outdent, protected: protected)
        {
            return nested
        }
        var changes: [(range: NSRange, replacement: String)] = []
        var offset = block.location
        repeat {
            let line = text.lineRange(for: NSRange(location: offset, length: 0))
            let value = text.substring(with: line)
            if outdent {
                let prefix = value.prefix { $0 == " " || $0 == "\t" }
                let count = prefix.first == "\t" ? 1 : prefix.prefix(2).prefix { $0 == " " }.count
                if count > 0 {
                    changes.append((NSRange(location: offset, length: count), ""))
                }
            } else {
                changes.append((NSRange(location: offset, length: 0), value.hasPrefix("\t") ? "\t" : "  "))
            }
            guard line.length > 0 else { break }
            offset = NSMaxRange(line)
        } while offset < NSMaxRange(block)
        guard !changes.isEmpty else { return nil }
        return Edit(
            range: block, expected: text.substring(with: block), replacements: changes, selection: kept)
    }

    private static func continueList(
        in source: String, selection: NSRange, protected: [NSRange]
    ) -> Edit? {
        let text = source as NSString
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: selection)
        guard NSMaxRange(selection) <= contentsEnd else { return nil }
        let line = text.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
        guard !line.contains(where: \.isNewline) else { return nil }
        let value = line as NSString
        guard
            let match = listPrefix.firstMatch(
                in: line, range: NSRange(location: 0, length: value.length)),
            selection.location >= lineStart + match.range.length
        else { return nil }
        let content = value.substring(from: match.range.length)
        if content.allSatisfy(\.isWhitespace) {
            let range = NSRange(location: lineStart, length: contentsEnd - lineStart)
            return Edit(
                range: range, expected: line, replacement: "",
                selection: NSRange(location: lineStart, length: 0))
        }
        func capture(_ index: Int) -> String {
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : value.substring(with: range)
        }
        let prefix: String
        if !capture(6).isEmpty {
            guard let number = Int(capture(6)), number < 999_999_999 else { return nil }
            prefix = capture(1) + String(number + 1) + capture(7) + capture(8)
        } else {
            let task = match.range(at: 4).location != NSNotFound
            prefix =
                capture(1) + capture(2) + capture(3)
                + (task ? "[ ]" + (capture(5).isEmpty ? " " : capture(5)) : "")
        }
        let newline: String
        if lineEnd > contentsEnd {
            newline = text.substring(with: NSRange(location: contentsEnd, length: lineEnd - contentsEnd))
        } else {
            newline = source.contains("\r\n") ? "\r\n" : source.contains("\r") ? "\r" : "\n"
        }
        let replacement = newline + prefix
        if !capture(6).isEmpty, let number = Int(capture(6)) {
            var changes: [(range: NSRange, replacement: String)] = [(selection, replacement)]
            changes += renumberSiblings(
                in: source, from: lineEnd, indentation: capture(1), delimiter: capture(7),
                start: number + 2, protected: protected)
            return edit(in: source, selection: selection, changes: changes)
        }
        return Edit(
            range: selection, expected: text.substring(with: selection), replacement: replacement,
            selection: NSRange(location: selection.location + replacement.utf16.count, length: 0))
    }

    private struct ListLine {
        let range: NSRange
        let indent: String
        let prefixLength: Int
        let number: Int?
        let delimiter: String
        let digits: NSRange?
    }

    private static func nestList(
        in source: String, block: NSRange, selection: NSRange, outdent: Bool, protected: [NSRange]
    ) -> Edit? {
        let text = source as NSString
        guard let current = listLine(in: text, at: block.location),
            !isProtected(current.range, ranges: protected)
        else { return nil }
        if outdent {
            return outdentList(
                in: source, current: current, block: block, selection: selection, protected: protected)
        }
        guard let parent = listItem(above: current, shallower: false, in: text, protected: protected)
        else { return nil }
        let target = String(repeating: " ", count: parent.prefixLength)
        let extra = target.utf16.count - current.indent.utf16.count
        guard extra > 0 else { return nil }
        let end = itemBlockEnd(in: text, after: block, indent: current.indent)
        var changes: [(range: NSRange, replacement: String)] = []
        var offset = current.range.location
        var number = nextNumber(
            in: text, from: NSMaxRange(parent.range), before: current.range.location, indent: target,
            delimiter: current.delimiter, start: 1)
        while offset < end {
            let line = text.lineRange(for: NSRange(location: offset, length: 0))
            changes.append((NSRange(location: offset, length: 0), String(repeating: " ", count: extra)))
            if let item = listLine(in: text, at: offset), item.indent == current.indent,
                let digits = item.digits, let value = number, item.delimiter == current.delimiter
            {
                changes.append((digits, String(value)))
                number = value + 1
            }
            offset = NSMaxRange(line)
        }
        if let vacated = current.number {
            changes += renumberSiblings(
                in: source, from: end, indentation: current.indent, delimiter: current.delimiter,
                start: vacated, protected: protected)
        }
        return edit(in: source, selection: selection, changes: changes)
    }

    private static func outdentList(
        in source: String, current: ListLine, block: NSRange, selection: NSRange, protected: [NSRange]
    ) -> Edit? {
        let text = source as NSString
        guard let parent = listItem(above: current, shallower: true, in: text, protected: protected)
        else { return nil }
        let extra = current.indent.utf16.count - parent.indent.utf16.count
        guard extra > 0 else { return nil }
        let end = itemBlockEnd(in: text, after: block, indent: current.indent)
        var changes: [(range: NSRange, replacement: String)] = []
        var offset = current.range.location
        var number = nextNumber(
            in: text, from: NSMaxRange(parent.range), before: current.range.location,
            indent: parent.indent,
            delimiter: current.delimiter.isEmpty ? parent.delimiter : current.delimiter,
            start: parent.number.map { $0 + 1 } ?? 1)
        while offset < end {
            let line = text.lineRange(for: NSRange(location: offset, length: 0))
            changes.append((NSRange(location: offset, length: extra), ""))
            if let item = listLine(in: text, at: offset), item.indent == current.indent,
                let digits = item.digits, let value = number
            {
                changes.append((digits, String(value)))
                number = value + 1
            }
            offset = NSMaxRange(line)
        }
        changes += renumberSiblings(
            in: source, from: end, indentation: current.indent, delimiter: current.delimiter,
            start: 1, protected: protected)
        if let following = number {
            changes += renumberSiblings(
                in: source, from: end, indentation: parent.indent,
                delimiter: current.delimiter.isEmpty ? parent.delimiter : current.delimiter,
                start: following, protected: protected)
        }
        return edit(in: source, selection: selection, changes: changes)
    }

    private static func listLine(in text: NSString, at offset: Int) -> ListLine? {
        let range = text.lineRange(for: NSRange(location: offset, length: 0))
        let line = text.substring(with: range).trimmingCharacters(in: .newlines)
        guard
            let match = listPrefix.firstMatch(
                in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return nil }
        func capture(_ index: Int) -> String {
            let group = match.range(at: index)
            return group.location == NSNotFound ? "" : (line as NSString).substring(with: group)
        }
        let digits = match.range(at: 6)
        let numberRange: NSRange?
        let number: Int?
        if digits.location != NSNotFound {
            numberRange = NSRange(location: range.location + digits.location, length: digits.length)
            number = Int((line as NSString).substring(with: digits))
        } else {
            numberRange = nil
            number = nil
        }
        return ListLine(
            range: range, indent: capture(1), prefixLength: match.range.length,
            number: number, delimiter: capture(7), digits: numberRange)
    }

    /// The nearest list item above `current` at its indent, or shallower than it.
    private static func listItem(
        above current: ListLine, shallower: Bool, in text: NSString, protected: [NSRange]
    ) -> ListLine? {
        var offset = current.range.location
        while offset > 0 {
            let previous = text.lineRange(for: NSRange(location: offset - 1, length: 0))
            offset = previous.location
            if isProtected(previous, ranges: protected) { return nil }
            guard let item = listLine(in: text, at: offset) else { continue }
            if item.indent.utf16.count < current.indent.utf16.count { return shallower ? item : nil }
            if !shallower, item.indent == current.indent { return item }
        }
        return nil
    }

    private static func itemBlockEnd(in text: NSString, after block: NSRange, indent: String) -> Int {
        var offset = NSMaxRange(block)
        var end = offset
        while offset < text.length {
            let line = text.lineRange(for: NSRange(location: offset, length: 0))
            let value = text.substring(with: line)
            let lineIndent = String(value.prefix { $0 == " " || $0 == "\t" })
            if lineIndent.utf16.count > indent.utf16.count {
                end = NSMaxRange(line)
                offset = end
            } else {
                break
            }
        }
        return end
    }

    private static func nextNumber(
        in text: NSString, from startOffset: Int, before offset: Int, indent: String, delimiter: String,
        start: Int
    ) -> Int? {
        guard !delimiter.isEmpty else { return nil }
        var number = start
        var scan = startOffset
        while scan < offset {
            if let item = listLine(in: text, at: scan), item.indent == indent,
                item.delimiter == delimiter, let value = item.number
            {
                number = value + 1
            }
            scan = NSMaxRange(text.lineRange(for: NSRange(location: scan, length: 0)))
        }
        return number
    }

    private static func renumberSiblings(
        in source: String, from offset: Int, indentation: String, delimiter: String,
        start number: Int, protected: [NSRange]
    ) -> [(range: NSRange, replacement: String)] {
        let text = source as NSString
        var changes: [(range: NSRange, replacement: String)] = []
        var cursor = offset
        var value = number
        while cursor < text.length, value <= 999_999_999 {
            let range = text.lineRange(for: NSRange(location: cursor, length: 0))
            let line = text.substring(with: range).trimmingCharacters(in: .newlines)
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            if indent.utf16.count > indentation.utf16.count {
                cursor = NSMaxRange(range)
                continue
            }
            guard indent == indentation,
                let match = listPrefix.firstMatch(
                    in: line, range: NSRange(location: 0, length: line.utf16.count)),
                match.range(at: 6).location != NSNotFound,
                (line as NSString).substring(with: match.range(at: 7)) == delimiter,
                !isProtected(range, ranges: protected)
            else { break }
            let digits = match.range(at: 6)
            changes.append(
                (NSRange(location: cursor + digits.location, length: digits.length), String(value)))
            value += 1
            cursor = NSMaxRange(range)
        }
        return changes
    }

    private static func edit(
        in source: String, selection: NSRange, changes: [(range: NSRange, replacement: String)]
    ) -> Edit? {
        guard !changes.isEmpty else { return nil }
        let start = changes.map(\.range.location).min()!
        let end = changes.map { NSMaxRange($0.range) }.max()!
        let range = NSRange(location: start, length: end - start)
        return Edit(
            range: range, expected: (source as NSString).substring(with: range),
            replacements: changes, selection: selection)
    }

    private static func protectedRanges(in source: String) -> [NSRange] {
        // Probe the next character so an EOF caret in an unfinished block stays protected.
        Syntax.spans(in: source + "\u{FFFC}").compactMap { span in
            span.kind == .code || span.kind == .frontmatter ? span.range : nil
        }
    }

    private static func isProtected(_ range: NSRange, ranges: [NSRange]) -> Bool {
        ranges.contains { protected in
            if range.length == 0 {
                return range.location >= protected.location && range.location < NSMaxRange(protected)
            }
            return NSIntersectionRange(range, protected).length > 0
        }
    }

    private static let listPrefix = try! NSRegularExpression(
        pattern: "^([ \\t]*)(?:([-*+])([ \\t]+)(?:\\[([ xX])\\]([ \\t]+|$))?|([0-9]{1,9})([.)])([ \\t]+))")
}
