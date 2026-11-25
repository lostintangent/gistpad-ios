import Foundation
import Markdown

extension MarkdownDocument {
    /// A run of source that reads as one Markdown construct.
    struct Span: Sendable, Equatable {
        enum Kind: Sendable {
            case heading, strong, emphasis, blockquote, htmlTag, strikethrough, orderedMarker
            case code, frontMatter, link, task, checkedTask, punctuation, linkDestination
        }

        let range: NSRange
        let kind: Kind
    }

    /// Every span in the note.
    var spans: [Span] { spans(in: range) }

    /// The spans of every prose run and literal `range` touches. Later spans override earlier ones.
    func spans(in range: NSRange) -> [Span] {
        var spans: [Span] = []
        func add(_ range: NSRange, _ kind: Span.Kind) {
            if range.length > 0 { spans.append(Span(range: range, kind: kind)) }
        }
        let runs = proseRuns(touching: range)
        var items: [ListItem] = []
        for run in runs {
            (text as NSString).enumerateSubstrings(in: run, options: [.byLines, .substringNotRequired]) {
                _, line, _, _ in
                if quoteMarker(at: line.location) != nil { add(line, .blockquote) }
                if headingMarker(at: line.location) != nil { add(line, .heading) }
                if let item = listItem(at: line.location, includingQuoted: true) { items.append(item) }
            }
        }
        if let first = runs.first, let last = runs.last {
            // Every match stays on one line, so one that starts outside a literal is prose.
            let prose = NSUnionRange(first, last)
            for (expression, groups) in Self.inlineStyles {
                for match in expression.matches(in: text, range: prose)
                where !isLiteral(NSRange(location: match.range.location, length: 0)) {
                    for (group, kind) in groups { add(match.range(at: group), kind) }
                }
            }
        }
        for item in items {
            if let box = item.box { add(box, item.isChecked ? .checkedTask : .task) }
            add(item.marker, item.number == nil ? .punctuation : .orderedMarker)
        }
        for literal in literals(touching: range) {
            add(literal.range, literal.kind == .code ? .code : .frontMatter)
            // A fence is markup, so it's highlighted like other line-leading markers.
            for fence in literal.fences { add(fence, .punctuation) }
        }
        for run in runs {
            for code in inlineCode(in: run) { add(code, .code) }
        }
        return spans
    }

    /// The whole lines whose spans can differ once `old` became this document by a change to
    /// `edited`, a range of this text, so `spans(in:)` over them and `old`'s spans elsewhere make
    /// `spans`. That's every prose run and literal the change touches in either document, grown
    /// until it splits none. Past it the text is the same and no literal is open, so it parses the
    /// same way.
    func spanRange(for edited: NSRange, from old: MarkdownDocument) -> NSRange {
        let delta = self.range.length - old.range.length
        var range = edited
        while true {
            let grown = old.runRange(around: NSRange(location: range.location, length: range.length - delta))
            let next = NSUnionRange(
                runRange(around: range), NSRange(location: grown.location, length: grown.length + delta))
            if next == range { return range }
            range = next
        }
    }

    /// Literals and inline code inside `range`, clipped to it, in order and merged.
    func protectedRanges(in range: NSRange) -> [NSRange] {
        let ranges = literals.map(\.range) + proseRuns(touching: range).flatMap { inlineCode(in: $0) }
        return ranges.compactMap { protected -> NSRange? in
            let clipped = NSIntersectionRange(protected, range)
            return clipped.length > 0 ? clipped : nil
        }
        .sorted { $0.location < $1.location }
        .reduce(into: []) { merged, next in
            if let last = merged.last, NSMaxRange(last) >= next.location {
                merged[merged.count - 1] = NSUnionRange(last, next)
            } else {
                merged.append(next)
            }
        }
    }

    /// The whole lines of `range`, grown to every prose run and literal they touch.
    private func runRange(around range: NSRange) -> NSRange {
        let lines = (text as NSString).lineRange(for: range)
        return (proseRuns(touching: lines) + literals(touching: lines).map(\.range)).reduce(lines, NSUnionRange)
    }

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
        try! NSRegularExpression(pattern: pattern)
    }
}
