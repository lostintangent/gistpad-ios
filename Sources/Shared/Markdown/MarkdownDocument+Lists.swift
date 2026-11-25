import Foundation

extension MarkdownDocument {
    /// Indents the selected lines, nesting a list item under the one above it.
    public func edit(indenting selection: NSRange, keeping kept: NSRange? = nil) -> MarkdownEdit? {
        indenting(selection, outdent: false, keeping: kept ?? selection)
    }

    /// Outdents the selected lines, lifting a nested list item to its parent's level.
    public func edit(outdenting selection: NSRange, keeping kept: NSRange? = nil) -> MarkdownEdit? {
        indenting(selection, outdent: true, keeping: kept ?? selection)
    }

    /// Whether `location`'s line is an unquoted list item. The end of the note counts as the last line.
    public func isListItem(at location: Int) -> Bool {
        guard location >= 0, location <= source.length else { return false }
        return listItem(at: min(location, max(0, source.length - 1))) != nil
    }

    /// Starts the item after `selection`'s, splitting its line there, with `text` after the new
    /// item's marker. The new item takes the next number, and an open box when this one has a box,
    /// and the numbered siblings below renumber. Nil outside an unquoted list item in prose, before
    /// its text, or past its line.
    public func edit(continuingListAt selection: NSRange, with text: String = "") -> MarkdownEdit? {
        let line = source.line(at: selection.location)
        guard NSMaxRange(selection) <= line.contentsEnd, let item = listItem(on: line),
            selection.location >= NSMaxRange(item.prefix), !isLiteral(selection)
        else { return nil }
        let newline =
            line.hasTerminator
            ? source.substring(with: NSRange(line.contentsEnd..<NSMaxRange(line.range)))
            : lineBreak
        let box = item.box == nil ? "" : "[ ]" + (item.boxSpacing.isEmpty ? " " : item.boxSpacing)
        var marker = item.bullet ?? ""
        var renumbering: [Change] = []
        if let number = item.number {
            guard number < 999_999_999 else { return nil }
            marker = String(number + 1) + item.delimiter
            renumbering = renumberingSiblings(
                from: NSMaxRange(line.range), indent: item.indent, delimiter: item.delimiter, start: number + 2)
        }
        return edit(
            changes: [(selection, newline + item.indent + marker + item.spacing + box + text)] + renumbering,
            selection: NSRange(location: NSMaxRange(selection), length: 0))
    }

    private func indenting(_ selection: NSRange, outdent: Bool, keeping kept: NSRange) -> MarkdownEdit? {
        let block = source.lineRange(covering: selection)
        guard !isLiteral(block) else { return nil }
        if let item = listItem(at: block.location) {
            let nested =
                outdent
                ? outdenting(item, block: block, keeping: kept) : nesting(item, block: block, keeping: kept)
            if let nested { return nested }
        }
        let changes = source.lines(in: block).compactMap { line -> Change? in
            let start = line.range.location
            if outdent {
                let first = start < line.contentsEnd ? source.character(at: start) : 0
                if first == 9 { return (NSRange(location: start, length: 1), "") }
                var count = 0
                while count < 2, start + count < line.contentsEnd, source.character(at: start + count) == 32 {
                    count += 1
                }
                return count > 0 ? (NSRange(location: start, length: count), "") : nil
            }
            let tab = start < line.contentsEnd && source.character(at: start) == 9
            return (NSRange(location: start, length: 0), tab ? "\t" : "  ")
        }
        return edit(changes: changes, selection: kept)
    }

    /// Nests `current` and its children at the content column of the item above it.
    private func nesting(_ current: ListItem, block: NSRange, keeping kept: NSRange) -> MarkdownEdit? {
        guard let parent = listItem(above: current, shallower: false) else { return nil }
        let target = String(repeating: " ", count: parent.prefix.length)
        let extra = target.utf16.count - current.indent.utf16.count
        guard extra > 0 else { return nil }
        let end = itemBlockEnd(after: block, indent: current.indent)
        var number = nextNumber(
            from: NSMaxRange(parent.line.range), before: current.line.range.location, indent: target,
            delimiter: current.delimiter, start: 1)
        var changes: [Change] = []
        var offset = current.line.range.location
        while offset < end {
            let line = source.line(at: offset)
            changes.append((NSRange(location: offset, length: 0), String(repeating: " ", count: extra)))
            if let item = listItem(on: line), item.indent == current.indent, item.delimiter == current.delimiter,
                let digits = item.digits, let value = number
            {
                changes.append((digits, String(value)))
                number = value + 1
            }
            offset = NSMaxRange(line.range)
        }
        if let vacated = current.number {
            changes += renumberingSiblings(
                from: end, indent: current.indent, delimiter: current.delimiter, start: vacated)
        }
        return edit(changes: changes, selection: kept)
    }

    /// Lifts `current` and its children to its parent's indent, renumbering both lists.
    private func outdenting(_ current: ListItem, block: NSRange, keeping kept: NSRange) -> MarkdownEdit? {
        guard let parent = listItem(above: current, shallower: true) else { return nil }
        let extra = current.indent.utf16.count - parent.indent.utf16.count
        guard extra > 0 else { return nil }
        let end = itemBlockEnd(after: block, indent: current.indent)
        let delimiter = current.delimiter.isEmpty ? parent.delimiter : current.delimiter
        var number = nextNumber(
            from: NSMaxRange(parent.line.range), before: current.line.range.location, indent: parent.indent,
            delimiter: delimiter, start: parent.number.map { $0 + 1 } ?? 1)
        var changes: [Change] = []
        var offset = current.line.range.location
        while offset < end {
            let line = source.line(at: offset)
            changes.append((NSRange(location: offset, length: extra), ""))
            if let item = listItem(on: line), item.indent == current.indent, let digits = item.digits,
                let value = number
            {
                changes.append((digits, String(value)))
                number = value + 1
            }
            offset = NSMaxRange(line.range)
        }
        changes += renumberingSiblings(
            from: end, indent: current.indent, delimiter: current.delimiter, start: 1)
        if let following = number {
            changes += renumberingSiblings(
                from: end, indent: parent.indent, delimiter: delimiter, start: following)
        }
        return edit(changes: changes, selection: kept)
    }

    /// The nearest unquoted item above `current` at its indent, or shallower than it.
    private func listItem(above current: ListItem, shallower: Bool) -> ListItem? {
        var offset = current.line.range.location
        while offset > 0 {
            let line = source.line(at: offset - 1)
            offset = line.range.location
            if isLiteral(line.range) { return nil }
            guard let item = listItem(on: line) else { continue }
            if item.indent.utf16.count < current.indent.utf16.count { return shallower ? item : nil }
            if !shallower, item.indent == current.indent { return item }
        }
        return nil
    }

    /// Where an item's children end: the lines after `block` indented deeper than `indent`.
    private func itemBlockEnd(after block: NSRange, indent: String) -> Int {
        var end = NSMaxRange(block)
        while end < source.length {
            let line = source.line(at: end)
            guard indentLength(of: line) > indent.utf16.count else { break }
            end = NSMaxRange(line.range)
        }
        return end
    }

    /// The number after the last sibling at `indent` between two offsets.
    private func nextNumber(
        from start: Int, before end: Int, indent: String, delimiter: String, start number: Int
    ) -> Int? {
        guard !delimiter.isEmpty else { return nil }
        var number = number
        var offset = start
        while offset < end {
            let line = source.line(at: offset)
            if let item = listItem(on: line), item.indent == indent, item.delimiter == delimiter,
                let value = item.number
            {
                number = value + 1
            }
            offset = NSMaxRange(line.range)
        }
        return number
    }

    /// Renumbers the numbered siblings from `offset` on, skipping their children.
    private func renumberingSiblings(
        from offset: Int, indent: String, delimiter: String, start number: Int
    ) -> [Change] {
        var changes: [Change] = []
        var offset = offset
        var number = number
        while offset < source.length, number <= 999_999_999 {
            let line = source.line(at: offset)
            offset = NSMaxRange(line.range)
            if indentLength(of: line) > indent.utf16.count { continue }
            guard let item = listItem(on: line), item.indent == indent,
                item.delimiter == delimiter, let digits = item.digits, !isLiteral(line.range)
            else { break }
            changes.append((digits, String(number)))
            number += 1
        }
        return changes
    }
}
