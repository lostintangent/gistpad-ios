import Foundation
import Markdown

/// What Ask shows: prose and the passages it cites, each found in the note.
package struct Answer: Sendable, Equatable {
    package var prose: String
    package var citations: [Citation] = []

    /// A passage the answer cites, at each range where the note's body has it.
    package struct Citation: Sendable, Equatable {
        package let text: String
        package let ranges: [NSRange]
    }

    /// The model's prose and the passages it cited, before they're checked.
    package struct Reply: Sendable, Equatable {
        package var prose: String
        var quotes: [String]

        nonisolated package init(prose: String, quotes: [String] = []) {
            self.prose = prose
            self.quotes = quotes
        }
    }
}

extension Answer {
    /// Finds each passage the reply cites in the note's body, or throws when one isn't there.
    init(_ reply: Reply, in document: MarkdownDocument) throws {
        prose = reply.prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : reply.prose
        guard !prose.isEmpty || !reply.quotes.isEmpty else { throw IntelligenceError.emptyAnswer }
        citations = try reply.quotes.map { quote in
            let ranges = document.text.exactRanges(of: quote).filter { $0.location >= document.contentStart }
            guard !ranges.isEmpty else { throw IntelligenceError.unverifiedQuotation }
            return Citation(text: quote, ranges: ranges)
        }
    }
}

extension Answer.Citation {
    /// The passage as Preview reads it, a line for each block. Headings, list items, quotes, tables
    /// and fences lose their Markdown, inline styles become attributes, and a paragraph's lines flow
    /// together. A table row's cells are separated by tabs, like a table copied from Notes.
    package var passage: AttributedString {
        let document = MarkdownDocument(text)
        let source = document.text as NSString
        /// The lines `range` touches from its start, each without the `>` that quotes it.
        func lines(in range: NSRange) -> [String] {
            var lines: [String] = []
            source.enumerateSubstrings(in: range, options: .byLines) { _, line, _, _ in
                let start = max(line.location, document.quoteMarker(at: line.location).map(NSMaxRange) ?? 0)
                lines.append(source.substring(with: NSRange(start..<NSMaxRange(line))))
            }
            return lines
        }
        func inline(_ markdown: String) -> AttributedString {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)
            return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        }
        let blocks = document.blocks.compactMap { block -> AttributedString? in
            switch block.kind {
            case .heading:
                return block.title.map { inline(source.substring(with: $0)) }
            case .paragraph, .listItem:
                let start = block.prefix.map(NSMaxRange) ?? block.range.location
                return inline(
                    lines(in: NSRange(start..<NSMaxRange(block.range)))
                        .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
            case .tableRow:
                let cells = source.substring(with: block.range).split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !cells.allSatisfy({ $0.wholeMatch(of: /:?-+:?/) != nil }) else { return nil }
                return inline(cells.joined(separator: "\t"))
            case .code:
                var code = lines(in: block.range).dropFirst()
                if code.last?.trimmingCharacters(in: .whitespaces).wholeMatch(of: /`{3,}|~{3,}/) != nil {
                    code.removeLast()
                }
                var passage = AttributedString(code.joined(separator: "\n"))
                passage.inlinePresentationIntent = .code
                return passage
            }
        }
        return blocks.reduce(into: AttributedString()) { passage, block in
            if !passage.characters.isEmpty { passage.append(AttributedString("\n")) }
            passage.append(block)
        }
    }
}
