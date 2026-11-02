import Foundation

struct PreviewFile: Equatable, Sendable {
    let text: String
    let id: String
    let generation: UInt64
    let allowsTaskEdits: Bool

    /// The renderer's protocol names the file's ID `documentID`.
    var arguments: [String: Any] {
        ["documentID": id, "generation": generation, "markdown": text, "allowsTaskEdits": allowsTaskEdits]
    }
}

enum PreviewBridge {
    enum Message: Equatable {
        case ready
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
        let documentID: String?
        let generation: UInt64?
        let edit: Edit?
        let kind: String?
        let target: String?
        let message: String?
    }

    static let invalidMessage = PreviewFailure("The preview sent an invalid message.")

    static func decode<Value: Decodable>(_ body: Any?) throws -> Value {
        guard let body, JSONSerialization.isValidJSONObject(body) else { throw invalidMessage }
        return try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: body))
    }

    /// Returns nil for messages from an older generation, and for task toggles the file doesn't allow.
    static func decode(_ body: Any, file: PreviewFile) throws -> Message? {
        let message: Envelope = try decode(body)
        if message.type == "ready" { return .ready }
        guard message.documentID == file.id, message.generation == file.generation else { return nil }
        switch message.type {
        case "taskToggle":
            guard file.allowsTaskEdits else { return nil }
            guard let edit = message.edit else { throw invalidMessage }
            let task = TaskToggleEdit(
                fileID: file.id,
                generation: file.generation,
                range: NSRange(location: edit.location, length: edit.length),
                expectedMarker: edit.expectedMarker,
                replacementMarker: edit.replacementMarker
            )
            guard task.isValid(in: file.text) else { throw invalidMessage }
            return .event(.taskToggle(task))
        case "link":
            guard let kind = message.kind.flatMap(PreviewLink.Kind.init), let target = message.target,
                  !target.isEmpty else { throw invalidMessage }
            if kind == .external {
                guard let url = URL(string: target),
                      let scheme = url.scheme?.lowercased(),
                      ["https", "http", "mailto"].contains(scheme),
                      url.user == nil, url.password == nil,
                      scheme == "mailto" || url.host != nil else {
                    throw invalidMessage
                }
            }
            return .event(.linkTapped(PreviewLink(
                fileID: file.id, generation: file.generation, kind: kind, target: target
            )))
        case "rendered":
            return .event(.rendered(fileID: file.id, generation: file.generation))
        case "failure":
            return .event(.failure(PreviewFailure(message.message ?? "The preview couldn't be rendered.")))
        default:
            throw invalidMessage
        }
    }
}
