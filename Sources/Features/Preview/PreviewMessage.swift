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

    static let invalidMessage = PreviewError("The preview sent an invalid message.")
}

/// A message the page posts to the app.
enum PreviewMessage: Equatable {
    case ready
    case rendered
    case commentActivate(segment: Int, start: Int, end: Int)
    case event(PreviewEvent)

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

    /// Fails for a message from an older generation, and for a task toggle the file doesn't allow.
    init?(_ body: Any, file: PreviewFile) throws {
        guard JSONSerialization.isValidJSONObject(body) else { throw PreviewError.invalidMessage }
        let message = try JSONDecoder().decode(Envelope.self, from: JSONSerialization.data(withJSONObject: body))
        if message.type == "ready" {
            self = .ready
            return
        }
        guard message.fileID == file.id, message.generation == file.generation else { return nil }
        switch message.type {
        case "taskToggle":
            guard file.allowsTaskEdits else { return nil }
            guard let edit = message.edit else { throw PreviewError.invalidMessage }
            let range = NSRange(location: edit.location, length: edit.length)
            guard file.isTaskToggle(range, from: edit.expectedMarker, to: edit.replacementMarker) else {
                throw PreviewError.invalidMessage
            }
            self = .event(.taskToggle(
                range: range, expected: edit.expectedMarker, replacement: edit.replacementMarker,
                generation: file.generation))
        case "link":
            guard let target = message.target, !target.isEmpty else { throw PreviewError.invalidMessage }
            switch message.kind {
            case "wikilink":
                self = .event(.openWikilink(target))
            case "external":
                guard let url = URL(string: target),
                      let scheme = url.scheme?.lowercased(),
                      ["https", "http", "mailto"].contains(scheme),
                      url.user == nil, url.password == nil,
                      scheme == "mailto" || url.host != nil else {
                    throw PreviewError.invalidMessage
                }
                self = .event(.openURL(url))
            default:
                throw PreviewError.invalidMessage
            }
        case "commentActivate":
            guard let segment = message.segment, let start = message.start, let end = message.end else {
                throw PreviewError.invalidMessage
            }
            self = .commentActivate(segment: segment, start: start, end: end)
        case "rendered":
            self = .rendered
        case "failure":
            self = .event(.failure(message.message ?? "The preview couldn’t be rendered."))
        default:
            throw PreviewError.invalidMessage
        }
    }
}

private extension PreviewFile {
    /// The web view is the untrusted side, so a toggle may only flip one task marker in the current text.
    func isTaskToggle(_ range: NSRange, from expected: String, to replacement: String) -> Bool {
        guard range.location >= 0, range.length == 3, range.location <= text.utf16.count - range.length,
              let swiftRange = Range(range, in: text) else { return false }
        return String(text[swiftRange]) == expected
            && ["[ ]", "[x]", "[X]"].contains(expected)
            && replacement == (expected == "[ ]" ? "[x]" : "[ ]")
    }
}
