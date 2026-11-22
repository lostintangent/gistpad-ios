import Foundation

struct PreviewFile: Equatable, Sendable {
    let text: String
    let id: String
    let generation: UInt64
    let allowsTaskEdits: Bool

    var arguments: [String: Any] {
        ["fileID": id, "generation": generation, "markdown": text, "allowsTaskEdits": allowsTaskEdits]
    }
}

struct PreviewError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

enum PreviewBridge {
    enum Message: Equatable {
        case ready
        case rendered
        case commentActivate(segment: Int, start: Int, end: Int)
        case event(PreviewEvent)
    }

    private struct Envelope: Decodable {
        struct Edit: Decodable {
            let location: Int
            let length: Int
            let expectedMarker: String
            let replacementMarker: String
        }
        let type: String
        let fileID: String?
        let generation: UInt64?
        let edit: Edit?
        let kind: String?
        let target: String?
        let message: String?
        let segment: Int?
        let start: Int?
        let end: Int?
    }

    static let invalidMessage = PreviewError("The preview sent an invalid message.")

    /// Returns nil for messages from an older generation, and for task toggles the file doesn't allow.
    static func decode(_ body: Any, file: PreviewFile) throws -> Message? {
        guard JSONSerialization.isValidJSONObject(body) else { throw invalidMessage }
        let message = try JSONDecoder().decode(Envelope.self, from: JSONSerialization.data(withJSONObject: body))
        if message.type == "ready" { return .ready }
        guard message.fileID == file.id, message.generation == file.generation else { return nil }
        switch message.type {
        case "taskToggle":
            guard file.allowsTaskEdits else { return nil }
            guard let edit = message.edit else { throw invalidMessage }
            let range = NSRange(location: edit.location, length: edit.length)
            guard isTaskToggle(range, from: edit.expectedMarker, to: edit.replacementMarker, in: file.text) else {
                throw invalidMessage
            }
            return .event(.taskToggle(
                range: range, expected: edit.expectedMarker, replacement: edit.replacementMarker,
                generation: file.generation))
        case "link":
            guard let target = message.target, !target.isEmpty else { throw invalidMessage }
            switch message.kind {
            case "wikilink":
                return .event(.openWikilink(target))
            case "external":
                guard let url = URL(string: target),
                      let scheme = url.scheme?.lowercased(),
                      ["https", "http", "mailto"].contains(scheme),
                      url.user == nil, url.password == nil,
                      scheme == "mailto" || url.host != nil else {
                    throw invalidMessage
                }
                return .event(.openURL(url))
            default:
                throw invalidMessage
            }
        case "commentActivate":
            guard let segment = message.segment, let start = message.start, let end = message.end else {
                throw invalidMessage
            }
            return .commentActivate(segment: segment, start: start, end: end)
        case "rendered":
            return .rendered
        case "failure":
            return .event(.failure(message.message ?? "The preview couldn't be rendered."))
        default:
            throw invalidMessage
        }
    }

    /// The web view is the untrusted side, so a toggle may only flip one task marker in the current text.
    private static func isTaskToggle(_ range: NSRange, from expected: String, to replacement: String, in text: String) -> Bool {
        guard range.location >= 0, range.length == 3, range.location <= text.utf16.count - range.length,
              let swiftRange = Range(range, in: text) else { return false }
        return String(text[swiftRange]) == expected
            && ["[ ]", "[x]", "[X]"].contains(expected)
            && replacement == (expected == "[ ]" ? "[x]" : "[ ]")
    }
}
