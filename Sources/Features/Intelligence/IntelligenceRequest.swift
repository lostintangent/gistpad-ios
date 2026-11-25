import Foundation
import Markdown

package enum IntelligenceAction: String, CaseIterable, Sendable {
    case ask, edit, review

    var title: String {
        switch self {
        case .ask: String(localized: "Ask", bundle: .module)
        case .edit: String(localized: "Edit", bundle: .module)
        case .review: String(localized: "Review", bundle: .module)
        }
    }
}

package struct IntelligenceRequest: Sendable {
    package let id: UUID
    package let document: MarkdownDocument
    let instruction: String

    /// Where a long request is, for the sheet's progress label.
    package enum Progress: Sendable {
        case reading(Int, of: Int)
        case editing(Int, of: Int)
        case reviewing(Int, of: Int)
        case combining(Int, of: Int)
        case answering
    }

    package init(document: MarkdownDocument, instruction: String = "", id: UUID = UUID()) {
        self.id = id
        self.document = document
        self.instruction = instruction
    }
}

package enum IntelligenceError: LocalizedError, Sendable, Equatable {
    case unavailable(String)
    case insufficientContext
    case invalidResponse
    case emptyAnswer
    case invalidAnswer(Answer.Issue)
    case invalidEdit
    case unsafeEdit
    case responseTooLarge
    case unverifiedQuotation
    case noEvidence
    case noteChanged
    case noApplicableChanges
    case refused
    case rateLimited
    case timedOut

    package var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .insufficientContext:
            String(
                localized:
                    "This request needs more context than the on-device model can safely combine. Your file is unchanged.",
                bundle: .module)
        case .invalidResponse:
            String(
                localized:
                    "Apple Intelligence returned a response the app couldn’t read. Your file is unchanged.",
                bundle: .module)
        case .responseTooLarge:
            String(
                localized:
                    "Apple Intelligence reached the response limit before finishing. Your file is unchanged.",
                bundle: .module)
        case .invalidEdit:
            String(
                localized:
                    "Apple Intelligence returned an edit that couldn’t be found in your file. Nothing was changed.",
                bundle: .module)
        case .emptyAnswer:
            String(
                localized: "Apple Intelligence didn’t return an answer. Try again.", bundle: .module)
        case .invalidAnswer:
            String(
                localized:
                    "Apple Intelligence couldn’t produce a clear, grounded answer. Try again.",
                bundle: .module)
        case .unsafeEdit:
            String(
                localized:
                    "This edit repeats your instruction or would leave almost none of your file. Nothing was changed.",
                bundle: .module)
        case .unverifiedQuotation:
            String(
                localized: "A quoted passage didn’t match your file.", bundle: .module)
        case .noEvidence:
            String(localized: "I couldn’t find that in this file.", bundle: .module)
        case .noteChanged:
            String(
                localized: "This file has changed since this result.",
                bundle: .module)
        case .noApplicableChanges:
            String(localized: "There are no verified changes to apply.", bundle: .module)
        case .refused:
            String(
                localized: "Apple Intelligence couldn’t complete this request. Your file is unchanged.",
                bundle: .module)
        case .rateLimited:
            String(localized: "Apple Intelligence is busy. Try again in a moment.", bundle: .module)
        case .timedOut:
            String(
                localized: "Apple Intelligence took too long to respond. Try again.", bundle: .module)
        }
    }
}
