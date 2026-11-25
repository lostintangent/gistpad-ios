import Foundation

extension MarkdownDocument {
    /// A run of source that reads as one Markdown construct, for styling.
    public struct Span: Sendable, Equatable {
        public enum Kind: Sendable {
            case heading, strong, emphasis, blockquote, htmlTag, strikethrough, orderedMarker
            case code, frontMatter, link, task, checkedTask, punctuation, linkDestination
        }

        public let range: NSRange
        public let kind: Kind
    }

    /// One structural block of the note, outside front matter.
    public struct Block: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case heading, paragraph, listItem, tableRow, code
        }

        public let kind: Kind
        /// Whole lines, without the last one's line break.
        public let range: NSRange
        public let level: Int?
        /// A list item's indent, marker, spacing and box.
        public let marker: NSRange?
        public let taskMarker: NSRange?

        init(
            _ kind: Kind, range: NSRange, level: Int? = nil, marker: NSRange? = nil,
            taskMarker: NSRange? = nil
        ) {
            self.kind = kind
            self.range = range
            self.level = level
            self.marker = marker
            self.taskMarker = taskMarker
        }
    }

    /// A list item's line, quoted or not.
    struct ListItem {
        let line: Line
        /// Everything before the item's text: indent, quote, marker, spacing and box.
        let prefix: NSRange
        let indent: String
        let isQuoted: Bool
        let bullet: String?
        let digits: NSRange?
        let number: Int?
        /// `.` or `)` for a numbered item, and empty for a bullet.
        let delimiter: String
        let spacing: String
        let box: NSRange?
        let boxSpacing: String
        let isChecked: Bool

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
            spacing = text(6)
            box = group(7)
            boxSpacing = text(8)
            isChecked = box.map { source.substring(with: $0) != "[ ]" } ?? false
        }
    }

    /// Every span in the note.
    public var spans: [Span] { spans(in: range) }

    /// The spans of the whole lines in `range`, with every literal and prose run it touches whole.
    /// Later spans paint over earlier ones.
    public func spans(in range: NSRange) -> [Span] {
        var spans: [Span] = []
        func add(_ range: NSRange, _ kind: Span.Kind) {
            if range.location != NSNotFound, range.length > 0 { spans.append(Span(range: range, kind: kind)) }
        }
        // Every match stays on one line, so one that starts outside a literal is prose.
        func prose(_ expression: NSRegularExpression) -> [NSTextCheckingResult] {
            expression.matches(in: text, range: range).filter {
                !isLiteral(NSRange(location: $0.range.location, length: 0))
            }
        }
        for match in prose(Self.quoteMarker) { add(match.range, .blockquote) }
        for match in prose(Self.headingMarker) { add(match.range, .heading) }
        for (expression, groups) in Self.inlineStyles {
            for match in prose(expression) {
                for (group, kind) in groups { add(match.range(at: group), kind) }
            }
        }
        for match in prose(Self.listMarker) {
            let item = ListItem(match, on: source.line(at: match.range.location), in: source)
            if let box = item.box { add(box, item.isChecked ? .checkedTask : .task) }
            if let digits = item.digits {
                add(NSRange(location: digits.location, length: digits.length + 1), .orderedMarker)
            }
            if item.bullet != nil { add(match.range(at: 3), .punctuation) }
        }
        for literal in literals where NSIntersectionRange(literal.range, range).length > 0 {
            add(literal.range, literal.kind == .code ? .code : .frontMatter)
            // A fence is markup, so it paints like other line-leading markers.
            for fence in literal.fences { add(fence, .punctuation) }
        }
        for run in proseRuns(touching: range) {
            for code in inlineCode(in: run) { add(code, .code) }
        }
        return spans
    }

    /// The note's blocks in order. Each fenced code block is one block, and front matter is none.
    public var blocks: [Block] {
        var blocks = literals.filter { $0.kind == .code }.map { literal in
            let end = source.line(at: NSMaxRange(literal.range) - 1).contentsEnd
            return Block(.code, range: NSRange(literal.range.location..<end))
        }
        for run in proseRuns {
            var current: Block?
            func finish(_ next: Block? = nil) {
                if let current { blocks.append(current) }
                current = next
            }
            for line in source.lines(in: run) {
                let contents = line.contents
                if let heading = Self.headingMarker.firstMatch(in: text, options: .anchored, range: contents) {
                    finish(Block(.heading, range: contents, level: heading.range(at: 2).length))
                    finish()
                } else if let item = listItem(on: line) {
                    finish(Block(.listItem, range: contents, marker: item.prefix, taskMarker: item.box))
                } else if source.substring(with: contents).trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    finish(Block(.tableRow, range: contents))
                } else if let block = current,
                    block.kind == .paragraph
                        || (block.kind == .listItem && indentLength(of: line) > 0)
                {
                    current = Block(
                        block.kind, range: NSUnionRange(block.range, contents), level: block.level,
                        marker: block.marker, taskMarker: block.taskMarker)
                } else {
                    finish(Block(.paragraph, range: contents))
                }
            }
            finish()
        }
        return blocks.sorted { $0.range.location < $1.range.location }
    }

    /// The note's prose on one line, up to 160 characters: its paragraphs and the text of its list
    /// items, without headings, tasks, tables or code. Nil when the note has none.
    public var excerpt: String? {
        let prose = blocks.compactMap { block -> NSRange? in
            switch block.kind {
            case .paragraph: block.range
            case .listItem where block.taskMarker == nil:
                block.marker.map { NSRange(NSMaxRange($0)..<NSMaxRange(block.range)) }
            default: nil
            }
        }
        let excerpt = prose.flatMap { source.substring(with: $0).split(whereSeparator: \.isNewline) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return excerpt.isEmpty ? nil : String(excerpt.prefix(160))
    }

    /// Every task box outside code and front matter, quoted ones included.
    public var taskMarkers: [NSRange] {
        proseRuns.flatMap { run in
            let code = inlineCode(in: run)
            return Self.listMarker.matches(in: text, range: run).compactMap { match -> NSRange? in
                let box = match.range(at: 7)
                guard box.location != NSNotFound,
                    !code.contains(where: { NSIntersectionRange($0, box).length > 0 })
                else { return nil }
                return box
            }
        }
    }

    /// The list item on `location`'s line. Typing and the keyboard bar leave quoted items alone.
    func listItem(at location: Int, includingQuoted: Bool = false) -> ListItem? {
        listItem(on: source.line(at: location), includingQuoted: includingQuoted)
    }

    func listItem(on line: Line, includingQuoted: Bool = false) -> ListItem? {
        guard let match = Self.listMarker.firstMatch(in: text, options: .anchored, range: line.contents)
        else { return nil }
        let item = ListItem(match, on: line, in: source)
        return includingQuoted || !item.isQuoted ? item : nil
    }

    // One grammar per construct. Each matches within a line.

    static let quoteMarker = expression(#"^( {0,3}>[ \t]?).*"#)
    /// Group 2 is the heading's level in hashes.
    static let headingMarker = expression(#"^( {0,3}(#{1,6})(?:[ \t]+|$)).*"#)
    static let headingClosing = expression(#"[ \t]+#+[ \t]*$"#)
    /// Indent, quote, bullet, digits, delimiter, spacing, box and the box's spacing.
    static let listMarker = expression(
        #"^([ \t]*)((?:>[ \t]*)*)(?:([-*+])|([0-9]{1,9})([.)]))([ \t]+)(?:(\[[ xX]\])([ \t]+|$))?"#)
    /// The fence, then its info string.
    static let fenceOpener = expression(
        #"^[ \t]*(?:>[ \t]*)*(?:(?:[-+*]|[0-9]{1,9}[.)])[ \t]+)?(`{3,}|~{3,})(.*)$"#)
    static let fenceCloser = expression(#"^[ \t]*(?:>[ \t]*)*(`{3,}|~{3,})[ \t]*$"#)

    private static let inlineStyles: [(NSRegularExpression, [(Int, Span.Kind)])] = [
        (expression(#"(?<!\\)(\*{3})(?=\S)(.+?\S|\S)\1"#), [(0, .strong), (0, .emphasis)]),
        (
            expression(#"(?<![\\_\p{L}\p{N}])(_{3})(?=\S)(.+?\S|\S)\1(?![_\p{L}\p{N}])"#),
            [(0, .strong), (0, .emphasis)]
        ),
        (expression(#"(?<!\\)(\*\*)(?=\S)(.+?\S|\S)\1"#), [(0, .strong)]),
        (expression(#"(?<![\\_\p{L}\p{N}])(__)(?=\S)(.+?\S|\S)\1(?![_\p{L}\p{N}])"#), [(0, .strong)]),
        (
            expression(
                #"(?<![\\*])\*(?!\*)(?=\S)(.+?\S|\S)(?<!\*)\*(?!\*)|(?<![\\_\p{L}\p{N}])_(?!_)(?=\S)(.+?\S|\S)(?<!_)_(?![_\p{L}\p{N}])"#
            ),
            [(0, .emphasis)]
        ),
        (expression(#"(?<!\\)(~~)(?=\S)(.+?\S|\S)\1"#), [(0, .strikethrough)]),
        (expression(#"(?<!\\)</?[A-Za-z][A-Za-z0-9-]*(?:[ \t]+[^<>\r\n]*?)?[ \t]*/?>"#), [(0, .htmlTag)]),
        (expression(#"(!?\[)([^\]\r\n]+)(\]\()([^\)\r\n]+)(\))"#), [(0, .link), (4, .linkDestination)]),
        (expression(#"(\[\[)([^\]\r\n]+)(\]\])"#), [(0, .link)]),
    ]

    private static func expression(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
    }
}
