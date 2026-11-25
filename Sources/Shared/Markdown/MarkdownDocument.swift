import Foundation

/// A note's Markdown source, read once.
///
/// Front matter and fenced code are literal, so Markdown inside them never counts. The rest is
/// prose, in runs of nonblank lines. Offsets are UTF-16, like `NSString` and TextKit.
public struct MarkdownDocument: Sendable, Equatable {
    public let text: String
    /// Where the body starts, after closed front matter and the blank lines below it.
    public let contentStart: Int
    /// Front matter and fenced code, in order.
    public let literals: [Literal]
    /// The runs of nonblank lines outside literals, in order. Inline code can span lines, but
    /// never a blank one or a literal.
    public let proseRuns: [NSRange]

    public init(_ text: String) {
        // One bridged copy keeps every later UTF-16 read and regular expression fast.
        let source = NSString(string: text)
        self.text = source as String
        var literals: [Literal] = []
        var contentStart = 0
        if let frontMatter = Self.frontMatter(in: source) {
            literals.append(frontMatter.literal)
            contentStart = frontMatter.contentStart
        }
        var cursor = literals.last.map { NSMaxRange($0.range) } ?? 0
        while let code = Self.codeBlock(in: source, from: cursor) {
            literals.append(code)
            cursor = NSMaxRange(code.range)
        }
        self.contentStart = contentStart
        self.literals = literals
        proseRuns = Self.proseRuns(in: source, around: literals)
    }

    /// Two documents are equal when their text is the same, code unit for code unit.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.text as NSString).isEqual(to: rhs.text)
    }

    /// The text after the front matter.
    public var body: String { source.substring(from: contentStart) }

    /// The whole text, in UTF-16 like every range here.
    public var range: NSRange { NSRange(location: 0, length: source.length) }

    var source: NSString { text as NSString }

    /// An edit that replaces `range` with `replacement`. A nil selection keeps the caret where it was.
    public func edit(
        replacing range: NSRange, with replacement: String, selection: NSRange? = nil
    ) -> MarkdownEdit {
        MarkdownEdit(document: self, range: range, replacement: replacement, selection: selection)
    }

    typealias Change = (range: NSRange, replacement: String)

    /// One edit for ordered, nonoverlapping changes, with `selection` carried through them.
    func edit(changes: [Change], selection: NSRange) -> MarkdownEdit? {
        guard let first = changes.first?.range.location,
            let end = changes.map({ NSMaxRange($0.range) }).max()
        else { return nil }
        return MarkdownEdit(
            document: self, range: NSRange(first..<end), replacements: changes, selection: selection)
    }

    /// The note's own line break, for lines an edit adds.
    var lineBreak: String { text.contains("\r\n") ? "\r\n" : text.contains("\r") ? "\r" : "\n" }

    /// The spaces and tabs that start `line`.
    func indentLength(of line: Line) -> Int {
        var end = line.range.location
        while end < line.contentsEnd, [32, 9].contains(source.character(at: end)) { end += 1 }
        return end - line.range.location
    }

    /// Front matter or a fenced code block, in whole lines with their terminators.
    public struct Literal: Sendable {
        public enum Kind: Sendable { case frontMatter, code }

        public let kind: Kind
        public let range: NSRange
        /// A code block's opening and closing fence lines.
        public let fences: [NSRange]
        public let isClosed: Bool
    }

    /// The literals `range` touches. An empty range touches the one it's in.
    public func literals(touching range: NSRange) -> ArraySlice<Literal> {
        Self.elements(of: literals, touching: range, at: \.range)
    }

    /// The prose runs `range` touches. An empty range touches the one it's in.
    public func proseRuns(touching range: NSRange) -> ArraySlice<NSRange> {
        Self.elements(of: proseRuns, touching: range, at: \.self)
    }

    /// Whether `range` touches a literal. A caret at the end of the note is inside a literal
    /// that hasn't closed yet, or one whose closing line has no terminator yet.
    public func isLiteral(_ range: NSRange) -> Bool {
        if range.length == 0, range.location == source.length {
            guard let last = literals.last, NSMaxRange(last.range) == source.length else { return false }
            return !last.isClosed || !source.line(at: source.length - 1).hasTerminator
        }
        return !literals(touching: range).isEmpty
    }

    /// Whether `range` touches a literal or inline code.
    public func isProtected(_ range: NSRange) -> Bool {
        if isLiteral(range) { return true }
        let end = max(NSMaxRange(range), range.location + 1)
        return proseRuns(touching: range).contains { run in
            inlineCode(in: run).contains { $0.location < end && NSMaxRange($0) > range.location }
        }
    }

    /// Code spans in a prose run. A run of backticks closes at the next run of the same length,
    /// and a backslash before an opener is literal.
    public func inlineCode(in run: NSRange) -> [NSRange] {
        var ticks: [(range: NSRange, escaped: Bool)] = []
        var offset = run.location
        while offset < NSMaxRange(run) {
            guard source.character(at: offset) == .backtick else {
                offset += 1
                continue
            }
            let start = offset
            while offset < NSMaxRange(run), source.character(at: offset) == .backtick { offset += 1 }
            var preceding = start
            while preceding > run.location, source.character(at: preceding - 1) == .backslash {
                preceding -= 1
            }
            ticks.append((NSRange(location: start, length: offset - start), (start - preceding) % 2 == 1))
        }
        var nextByLength: [Int: Int] = [:]
        var closers = [Int?](repeating: nil, count: ticks.count)
        for index in ticks.indices.reversed() {
            let tick = ticks[index]
            closers[index] = nextByLength[tick.range.length - (tick.escaped ? 1 : 0)]
            nextByLength[tick.range.length] = index
        }
        var code: [NSRange] = []
        var index = 0
        while index < ticks.count {
            let tick = ticks[index]
            if tick.range.length > (tick.escaped ? 1 : 0), let closer = closers[index] {
                let start = tick.range.location + (tick.escaped ? 1 : 0)
                code.append(NSRange(location: start, length: NSMaxRange(ticks[closer].range) - start))
                index = closer + 1
            } else {
                index += 1
            }
        }
        return code
    }

    /// Front matter opens on the first line with `---` and closes at the next `---` line that
    /// ends with a line break. Until it closes, it runs to the end and hides nothing.
    private static func frontMatter(in source: NSString) -> (literal: Literal, contentStart: Int)? {
        func isFence(_ line: Line) -> Bool {
            let text = source.substring(with: line.contents)
            return text.hasPrefix("---") && text.dropFirst(3).allSatisfy(\.isWhitespace)
        }
        guard source.length > 0, isFence(source.line(at: 0)) else { return nil }
        var end = NSMaxRange(source.line(at: 0).range)
        while end < source.length {
            let line = source.line(at: end)
            end = NSMaxRange(line.range)
            guard isFence(line), line.hasTerminator else { continue }
            var contentStart = end
            while contentStart < source.length {
                let blank = source.line(at: contentStart)
                guard blank.hasTerminator, source.isBlank(blank.contents) else { break }
                contentStart = NSMaxRange(blank.range)
            }
            return (Literal(kind: .frontMatter, range: NSRange(0..<end), fences: [], isClosed: true), contentStart)
        }
        return (Literal(kind: .frontMatter, range: NSRange(0..<end), fences: [], isClosed: false), 0)
    }

    /// The next fenced code block at or after `offset`, which is a line start. It closes at a
    /// fence of the same character that's at least as long, or runs to the end.
    private static func codeBlock(in source: NSString, from offset: Int) -> Literal? {
        var cursor = offset
        let text = source as String
        while cursor < source.length,
            let opener = Self.fenceOpener.firstMatch(
                in: text, range: NSRange(location: cursor, length: source.length - cursor))
        {
            let opening = source.line(at: opener.range.location)
            let fence = opener.range(at: 1)
            let character = source.character(at: fence.location)
            cursor = NSMaxRange(opening.range)
            guard character != .backtick
                || source.range(of: "`", options: [], range: opener.range(at: 2)).location == NSNotFound
            else { continue }
            var scan = cursor
            while scan < source.length,
                let closer = Self.fenceCloser.firstMatch(
                    in: text, range: NSRange(location: scan, length: source.length - scan))
            {
                let closing = source.line(at: closer.range.location)
                let delimiter = closer.range(at: 1)
                if source.character(at: delimiter.location) == character, delimiter.length >= fence.length {
                    return Literal(
                        kind: .code, range: NSRange(opening.range.location..<NSMaxRange(closing.range)),
                        fences: [opening.range, closing.range], isClosed: true)
                }
                scan = NSMaxRange(closing.range)
            }
            return Literal(
                kind: .code, range: NSRange(opening.range.location..<source.length), fences: [opening.range],
                isClosed: false)
        }
        return nil
    }

    /// The elements of `ordered`, whose ranges are in order and never overlap, that `range` touches.
    private static func elements<Element>(
        of ordered: [Element], touching range: NSRange, at element: (Element) -> NSRange
    ) -> ArraySlice<Element> {
        let end = max(NSMaxRange(range), range.location + 1)
        let start = ordered.partitioningIndex { NSMaxRange(element($0)) > range.location }
        let stop = ordered[start...].partitioningIndex { element($0).location >= end }
        return ordered[start..<stop]
    }

    private static func proseRuns(in source: NSString, around literals: [Literal]) -> [NSRange] {
        var runs: [NSRange] = []
        let gaps = zip(
            [0] + literals.map { NSMaxRange($0.range) }, literals.map(\.range.location) + [source.length])
        for (gapStart, gapEnd) in gaps {
            var start: Int?
            var offset = gapStart
            while offset < gapEnd {
                let line = source.line(at: offset)
                if source.isBlank(line.contents) {
                    if let first = start { runs.append(NSRange(location: first, length: offset - first)) }
                    start = nil
                } else if start == nil {
                    start = offset
                }
                offset = NSMaxRange(line.range)
            }
            if let first = start { runs.append(NSRange(location: first, length: gapEnd - first)) }
        }
        return runs
    }
}

/// One line of a note, with UTF-16 offsets.
struct Line {
    /// The line with its terminator.
    let range: NSRange
    let contentsEnd: Int

    var contents: NSRange { NSRange(location: range.location, length: contentsEnd - range.location) }
    var hasTerminator: Bool { contentsEnd < NSMaxRange(range) }
}

extension NSString {
    func line(at location: Int) -> Line {
        var start = 0
        var end = 0
        var contentsEnd = 0
        getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return Line(range: NSRange(location: start, length: end - start), contentsEnd: contentsEnd)
    }

    /// The lines of `range`, which is whole lines. There's always at least one, and a range that
    /// ends with a line break doesn't include the empty line after it.
    func lines(in range: NSRange) -> [Line] {
        var lines: [Line] = []
        var offset = range.location
        repeat {
            let line = line(at: offset)
            lines.append(line)
            offset = NSMaxRange(line.range)
        } while offset < NSMaxRange(range)
        return lines
    }

    /// The whole lines a selection touches. Unlike `lineRange(for:)`, a selection that ends just
    /// after a line break leaves the next line out.
    func lineRange(covering selection: NSRange) -> NSRange {
        let first = lineRange(for: NSRange(location: selection.location, length: 0))
        let last = lineRange(
            for: NSRange(location: max(selection.location, NSMaxRange(selection) - 1), length: 0))
        return NSUnionRange(first, last)
    }

    func isBlank(_ range: NSRange) -> Bool {
        rangeOfCharacter(from: Self.visible, range: range).location == NSNotFound
    }

    private static let visible = CharacterSet.whitespacesAndNewlines.inverted
}

extension unichar {
    static let backtick: unichar = 0x60
    static let backslash: unichar = 0x5C
}

extension Collection {
    /// The first index where `belongs` holds, for a predicate that's false and then true.
    func partitioningIndex(where belongs: (Element) -> Bool) -> Index {
        var low = startIndex
        var count = self.count
        while count > 0 {
            let half = count / 2
            let middle = index(low, offsetBy: half)
            if belongs(self[middle]) {
                count = half
            } else {
                low = index(after: middle)
                count -= half + 1
            }
        }
        return low
    }
}
