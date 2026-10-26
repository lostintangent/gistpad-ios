import Foundation

public struct TaskToggleEdit: Equatable, Sendable {
    public let documentID: String
    public let generation: UInt64
    public let range: NSRange
    public let expectedMarker: String
    public let replacementMarker: String

    public init(
        documentID: String,
        generation: UInt64,
        range: NSRange,
        expectedMarker: String,
        replacementMarker: String
    ) {
        self.documentID = documentID
        self.generation = generation
        self.range = range
        self.expectedMarker = expectedMarker
        self.replacementMarker = replacementMarker
    }

    public func validate(in document: String, documentID: String, generation: UInt64) throws {
        guard self.documentID == documentID, self.generation == generation else {
            throw PreviewFailure.staleDocument
        }
        guard range.location >= 0, range.length == 3,
              range.location <= document.utf16.count - range.length,
              let swiftRange = Range(range, in: document),
              String(document[swiftRange]) == expectedMarker,
              ["[ ]", "[x]", "[X]"].contains(expectedMarker),
              replacementMarker == (expectedMarker == "[ ]" ? "[x]" : "[ ]") else {
            throw PreviewFailure.invalidTaskEdit
        }
    }
}

public struct PreviewLink: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case external
        case wikilink
        case anchor
    }

    public let documentID: String
    public let generation: UInt64
    public let kind: Kind
    public let target: String
}

public enum PreviewFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidMessage
    case staleDocument
    case invalidTaskEdit
    case documentTooLarge
    case renderer(String)

    static func webKit(_ error: Error) -> Self {
        let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
        return .renderer(String((detail ?? error.localizedDescription).prefix(512)))
    }

    public var errorDescription: String? {
        switch self {
        case .invalidMessage: "The preview sent an invalid message."
        case .staleDocument: "The preview is out of date. Try the action again."
        case .invalidTaskEdit: "The task changed before this action could be applied."
        case .documentTooLarge: "This document is too large to preview."
        case .renderer(let message): message
        }
    }
}

public enum PreviewEvent: Equatable, Sendable {
    case taskToggle(TaskToggleEdit)
    case linkTapped(PreviewLink)
    case rendered(documentID: String, generation: UInt64)
    case failure(PreviewFailure)
}
