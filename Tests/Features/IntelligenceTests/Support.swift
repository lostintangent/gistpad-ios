import Foundation
import Markdown

@testable import Intelligence

func note(_ source: String) -> MarkdownDocument { MarkdownDocument(source) }

func request(_ source: String, _ instruction: String = "") -> IntelligenceRequest {
    IntelligenceRequest(document: note(source), instruction: instruction)
}

/// The model revising everything it was shown.
func rewrite(_ revised: String) -> (ModelPass) -> [EditOperation] {
    { [.rewriteRegion(NSRange(location: 0, length: $0.source.utf16.count), revised: revised)] }
}

func change(_ quote: String, _ replacement: String?) -> Proposal.Change {
    Proposal.Change(quote: quote, replacement: replacement, reason: "Improve")
}

extension Proposal {
    init(document: MarkdownDocument, candidates: [Proposal.Change]) {
        self.init(document: document, scopedCandidates: candidates.map { ($0, document.range) })
    }
}
