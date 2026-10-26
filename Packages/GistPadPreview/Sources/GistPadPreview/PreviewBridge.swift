import Foundation

struct PreviewDocument: Equatable, Sendable {
    static let maximumLength = 2 * 1024 * 1024
    let text: String
    let id: String
    let generation: UInt64

    var arguments: [String: Any] {
        [
            "version": 1,
            "documentID": id,
            // Decimal strings preserve all UInt64 generations across JavaScript's number boundary.
            "generation": String(generation),
            "markdown": text
        ]
    }

    func validate() throws {
        guard !id.isEmpty, id.utf16.count <= 512 else { throw PreviewFailure.invalidMessage }
        guard text.utf16.count <= Self.maximumLength else { throw PreviewFailure.documentTooLarge }
    }
}

enum PreviewBridge {
    enum Message {
        case ready
        case obsolete
        case taskEditingUnavailable
        case event(PreviewEvent)
    }

    private struct Envelope: Decodable {
        struct Edit: Decodable {
            let location: Int
            let length: Int
            let expectedMarker: String
            let replacementMarker: String
        }
        let version: Int
        let type: String
        let documentID: String?
        let generation: String?
        let edit: Edit?
        let kind: String?
        let target: String?
        let message: String?
    }

    static func decode<Value: Decodable>(_ body: Any, maximumBytes: Int) throws -> Value {
        guard JSONSerialization.isValidJSONObject(body) else { throw PreviewFailure.invalidMessage }
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= maximumBytes else { throw PreviewFailure.invalidMessage }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw PreviewFailure.invalidMessage
        }
    }

    static func decode(_ body: Any, document: PreviewDocument, allowsTaskEdits: Bool = true) throws -> Message {
        let message: Envelope = try decode(body, maximumBytes: 16_384)
        guard message.version == 1 else { throw PreviewFailure.invalidMessage }
        if message.type == "ready" { return .ready }
        guard message.documentID == document.id,
              message.generation == String(document.generation) else {
            if ["rendered", "failure"].contains(message.type) { return .obsolete }
            throw PreviewFailure.staleDocument
        }
        switch message.type {
        case "taskToggle":
            guard let edit = message.edit else { throw PreviewFailure.invalidMessage }
            let task = TaskToggleEdit(
                documentID: document.id,
                generation: document.generation,
                range: NSRange(location: edit.location, length: edit.length),
                expectedMarker: edit.expectedMarker,
                replacementMarker: edit.replacementMarker
            )
            try task.validate(in: document.text, documentID: document.id, generation: document.generation)
            guard allowsTaskEdits else { return .taskEditingUnavailable }
            return .event(.taskToggle(task))
        case "link":
            guard let rawKind = message.kind, let kind = PreviewLink.Kind(rawValue: rawKind),
                  let target = message.target, !target.isEmpty, target.utf16.count <= 8192,
                  !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw PreviewFailure.invalidMessage
            }
            if kind == .external {
                guard let url = URL(string: target),
                      let scheme = url.scheme?.lowercased(),
                      ["https", "http", "mailto"].contains(scheme),
                      url.user == nil, url.password == nil,
                      scheme == "mailto" || url.host != nil else {
                    throw PreviewFailure.invalidMessage
                }
            }
            return .event(.linkTapped(PreviewLink(
                documentID: document.id, generation: document.generation, kind: kind, target: target
            )))
        case "rendered":
            return .event(.rendered(documentID: document.id, generation: document.generation))
        case "failure":
            guard let text = message.message, !text.isEmpty, text.utf16.count <= 512 else {
                throw PreviewFailure.invalidMessage
            }
            return .event(.failure(.renderer(text)))
        default:
            throw PreviewFailure.invalidMessage
        }
    }
}
