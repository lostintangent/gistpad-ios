import Foundation

public struct TaskToggleEdit: Equatable, Sendable {
    public let generation: UInt64
    public let range: NSRange
    public let expectedMarker: String
    public let replacementMarker: String

    /// The web view is the untrusted side, so a toggle may only flip one task marker in the current text.
    func isValid(in text: String) -> Bool {
        guard range.location >= 0, range.length == 3, range.location <= text.utf16.count - range.length,
              let swiftRange = Range(range, in: text) else { return false }
        return String(text[swiftRange]) == expectedMarker
            && ["[ ]", "[x]", "[X]"].contains(expectedMarker)
            && replacementMarker == (expectedMarker == "[ ]" ? "[x]" : "[ ]")
    }
}

public struct PreviewLink: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case external
        case wikilink
    }

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
    case failure(PreviewFailure)
}
