import Foundation

extension MarkdownDocument {
    /// The note as Preview renders it, a line for each block. Headings, list items, quotes, tables
    /// and fences lose their Markdown, inline styles become attributes, and a paragraph's lines flow
    /// together. A table row's cells are separated by tabs, like a table copied from Notes.
    public var renderedText: AttributedString {
        blocks.compactMap(rendered).reduce(into: AttributedString()) { text, block in
            if !text.characters.isEmpty { text.append(AttributedString("\n")) }
            text.append(block)
        }
    }

    /// The note's prose on one line as Preview renders it, up to 160 characters: its paragraphs
    /// and the text of its list items, without headings, tasks, tables or code. Nil when the note
    /// has none.
    public var excerpt: String? {
        let prose = blocks.lazy
            .filter { $0.kind == .paragraph || ($0.kind == .listItem && $0.box == nil) }
            .compactMap { self.rendered($0).map { String($0.characters) } }
            .filter { !$0.isEmpty }
        var excerpt = ""
        for line in prose {
            excerpt += excerpt.isEmpty ? line : " \(line)"
            if excerpt.count >= 160 { break }
        }
        return excerpt.isEmpty ? nil : String(excerpt.prefix(160))
    }

    /// `block` as Preview renders it, or nil for a table's alignment row.
    private func rendered(_ block: Block) -> AttributedString? {
        /// The block's lines from `start`, each without the `>` that quotes it.
        func lines(from start: Int) -> [String] {
            source.lines(in: block.range).map { line in
                let start = max(start, line.range.location, quoteMarker(on: line).map(NSMaxRange) ?? 0)
                return source.substring(with: NSRange(start..<line.contentsEnd))
            }
        }
        func inline(_ markdown: String) -> AttributedString {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)
            return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        }
        switch block.kind {
        case .heading:
            return block.title.map { inline(source.substring(with: $0)) }
        case .paragraph, .listItem:
            let start = block.prefix.map(NSMaxRange) ?? block.range.location
            return inline(lines(from: start).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
        case .tableRow:
            let cells = source.substring(with: block.range).split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !cells.allSatisfy({ $0.wholeMatch(of: /:?-+:?/) != nil }) else { return nil }
            return inline(cells.joined(separator: "\t"))
        case .code:
            var code = lines(from: block.range.location).dropFirst()
            if code.last?.trimmingCharacters(in: .whitespaces).wholeMatch(of: /`{3,}|~{3,}/) != nil {
                code.removeLast()
            }
            var text = AttributedString(code.joined(separator: "\n"))
            text.inlinePresentationIntent = .code
            return text
        }
    }
}
