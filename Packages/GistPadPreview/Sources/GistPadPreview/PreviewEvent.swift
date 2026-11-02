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

    /// The web view is the untrusted side, so a toggle may only flip one task marker in the current text.
    func isValid(in document: String) -> Bool {
        guard range.location >= 0, range.length == 3, range.location <= document.utf16.count - range.length,
              let swiftRange = Range(range, in: document) else { return false }
        return String(document[swiftRange]) == expectedMarker
            && ["[ ]", "[x]", "[X]"].contains(expectedMarker)
            && replacementMarker == (expectedMarker == "[ ]" ? "[x]" : "[ ]")
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

public struct PreviewFailure: LocalizedError, Equatable, Sendable {
    public let errorDescription: String?

    public init(_ message: String) {
        errorDescription = message
    }

    init(_ error: any Error) {
        let error = error as NSError
        self.init(error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
    }
}

public enum PreviewEvent: Equatable, Sendable {
    case taskToggle(TaskToggleEdit)
    case linkTapped(PreviewLink)
    case rendered(documentID: String, generation: UInt64)
    case failure(PreviewFailure)
}
