import Foundation

extension MarkdownDocument {
    /// One structural block of the note, outside front matter.
    public struct Block: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case heading, paragraph, listItem, tableRow, code
        }

        public let kind: Kind
        /// Whole lines, without the last one's line break.
        public let range: NSRange
        public let level: Int?
        /// A heading's text, without its hashes or the spaces around it.
        public let title: NSRange?
        /// Everything before a list item's text: its indent, marker, spacing and box.
        public let prefix: NSRange?
        /// A task's box.
        public let box: NSRange?

        init(
            _ kind: Kind, range: NSRange, level: Int? = nil, title: NSRange? = nil, prefix: NSRange? = nil,
            box: NSRange? = nil
        ) {
            self.kind = kind
            self.range = range
            self.level = level
            self.title = title
            self.prefix = prefix
            self.box = box
        }
    }

    /// A heading and the blocks under it, up to the next heading of any level.
    public struct Section: Sendable, Equatable {
        /// Nil for the blocks before the note's first heading.
        public let heading: Block?
        /// Whole lines, from the section's first block through its last, without the last line break.
        public let range: NSRange
    }

    /// A list item's line, quoted or not.
    public struct ListItem: Sendable {
        let line: Line
        /// Everything before the item's text: indent, quote, marker, spacing and box.
        public let prefix: NSRange
        /// The bullet, or the number with its `.` or `)`.
        public let marker: NSRange
        public let number: Int?
        public let box: NSRange?
        public let isChecked: Bool
        public let isQuoted: Bool
        let indent: String
        let bullet: String?
        let digits: NSRange?
        /// `.` or `)` for a numbered item, and empty for a bullet.
        let delimiter: String
        let spacing: String
        let boxSpacing: String

        /// The line, without its line break.
        public var range: NSRange { line.contents }

        init(_ match: NSTextCheckingResult, on line: Line, in source: NSString) {
            func group(_ index: Int) -> NSRange? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : range
            }
            func text(_ index: Int) -> String { group(index).map(source.substring(with:)) ?? "" }
            self.line = line
            prefix = match.range
            indent = text(1)
            isQuoted = !text(2).isEmpty
            bullet = group(3).map(source.substring(with:))
            digits = group(4)
            number = digits.flatMap { Int(source.substring(with: $0)) }
            delimiter = text(5)
            marker = group(3) ?? NSUnionRange(match.range(at: 4), match.range(at: 5))
            spacing = text(6)
            box = group(7)
            boxSpacing = text(8)
            isChecked = box.map { source.substring(with: $0) != "[ ]" } ?? false
        }
    }

    /// The note's blocks in order. Each fenced code block is one block, and front matter is none.
    public var blocks: [Block] { blocks(in: range) }

    /// The blocks of every prose run and code block `range` touches, in order.
    public func blocks(in range: NSRange) -> [Block] {
        var blocks = literals(touching: range).filter { $0.kind == .code }.map { literal in
            let end = source.line(at: NSMaxRange(literal.range) - 1).contentsEnd
            return Block(.code, range: NSRange(literal.range.location..<end))
        }
        for run in proseRuns(touching: range) {
            var current: Block?
            func finish(_ next: Block? = nil) {
                if let current { blocks.append(current) }
                current = next
            }
            for line in source.lines(in: run) {
                let contents = line.contents
                if let heading = Self.headingMarker.firstMatch(in: text, options: .anchored, range: contents) {
                    finish(
                        Block(
                            .heading, range: contents, level: heading.range(at: 2).length,
                            title: title(of: heading, on: contents)))
                    finish()
                } else if let item = listItem(on: line) {
                    finish(Block(.listItem, range: contents, prefix: item.prefix, box: item.box))
                } else if source.substring(with: contents).trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    finish(Block(.tableRow, range: contents))
                } else if let block = current,
                    block.kind == .paragraph
                        || (block.kind == .listItem && indentLength(of: line) > 0)
                {
                    current = Block(
                        block.kind, range: NSUnionRange(block.range, contents), prefix: block.prefix,
                        box: block.box)
                } else {
                    finish(Block(.paragraph, range: contents))
                }
            }
            finish()
        }
        return blocks.sorted { $0.range.location < $1.range.location }
    }

    /// The text after a heading's marker, up to its closing hashes and trailing spaces.
    private func title(of marker: NSTextCheckingResult, on contents: NSRange) -> NSRange {
        let hashes = NSMaxRange(marker.range(at: 2))
        var end =
            Self.headingClosing.firstMatch(in: text, range: NSRange(hashes..<NSMaxRange(contents)))?.range.location
            ?? NSMaxRange(contents)
        let start = min(NSMaxRange(marker.range), end)
        while end > start, [32, 9].contains(source.character(at: end - 1)) { end -= 1 }
        return NSRange(start..<end)
    }

    /// The note's sections in order. Blocks before the first heading make a section with no heading.
    public var sections: [Section] {
        blocks.reduce(into: []) { sections, block in
            if block.kind == .heading || sections.isEmpty {
                sections.append(Section(heading: block.kind == .heading ? block : nil, range: block.range))
            } else {
                let section = sections.removeLast()
                sections.append(Section(heading: section.heading, range: NSUnionRange(section.range, block.range)))
            }
        }
    }

    /// Every task outside code and front matter, quoted ones included: the list items with a box.
    public var tasks: [ListItem] {
        proseRuns.flatMap { run in
            let code = inlineCode(in: run)
            return source.lines(in: run).compactMap { line -> ListItem? in
                guard let item = listItem(on: line, includingQuoted: true), let box = item.box,
                    !code.contains(where: { NSIntersectionRange($0, box).length > 0 })
                else { return nil }
                return item
            }
        }
    }

    /// The list item on `location`'s line, whatever its context. Typing and the keyboard bar
    /// leave quoted items alone.
    public func listItem(at location: Int, includingQuoted: Bool = false) -> ListItem? {
        listItem(on: source.line(at: location), includingQuoted: includingQuoted)
    }

    func listItem(on line: Line, includingQuoted: Bool = false) -> ListItem? {
        guard let match = Self.listMarker.firstMatch(in: text, options: .anchored, range: line.contents)
        else { return nil }
        let item = ListItem(match, on: line, in: source)
        return includingQuoted || !item.isQuoted ? item : nil
    }

    /// The `>` and the space after it that quote `location`'s line, whatever its context.
    public func quoteMarker(at location: Int) -> NSRange? {
        quoteMarker(on: source.line(at: location))
    }

    /// The hashes and the space after them that make `location`'s line a heading, whatever its context.
    public func headingMarker(at location: Int) -> NSRange? {
        Self.headingMarker.firstMatch(in: text, options: .anchored, range: source.line(at: location).contents)?
            .range
    }

    func quoteMarker(on line: Line) -> NSRange? {
        Self.quoteMarker.firstMatch(in: text, options: .anchored, range: line.contents)?.range
    }

    // One grammar per construct. Each matches within a line.

    static let quoteMarker = expression(#"^ {0,3}>[ \t]?"#)
    /// Group 2 is the heading's level in hashes.
    static let headingMarker = expression(#"^( {0,3}(#{1,6})(?:[ \t]+|$))"#)
    static let headingClosing = expression(#"[ \t]+#+[ \t]*$"#)
    /// Indent, quote, bullet, digits, delimiter, spacing, box and the box's spacing.
    static let listMarker = expression(
        #"^([ \t]*)((?:>[ \t]*)*)(?:([-*+])|([0-9]{1,9})([.)]))([ \t]+)(?:(\[[ xX]\])([ \t]+|$))?"#)
    /// The fence, then its info string.
    static let fenceOpener = expression(
        #"^[ \t]*(?:>[ \t]*)*(?:(?:[-+*]|[0-9]{1,9}[.)])[ \t]+)?(`{3,}|~{3,})(.*)$"#)
    static let fenceCloser = expression(#"^[ \t]*(?:>[ \t]*)*(`{3,}|~{3,})[ \t]*$"#)

    private static func expression(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
    }
}
