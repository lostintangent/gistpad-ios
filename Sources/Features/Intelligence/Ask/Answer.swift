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
    /// The passage as Preview renders it.
    package var passage: AttributedString { MarkdownDocument(text).renderedText }
}
