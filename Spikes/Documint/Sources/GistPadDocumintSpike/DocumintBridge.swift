import Foundation
import GistPadEditor

enum DocumintBridge {
    static let maximumLength = 2 * 1024 * 1024

    struct Message: Decodable {
        let version: Int
        let type: String
        let documentID: String?
        let generation: String?
        let revision: Int?
        let markdown: String?
        let message: String?
        let milliseconds: Double?
    }

    static func decode(_ body: Any) throws -> Message {
        guard JSONSerialization.isValidJSONObject(body) else { throw Failure.invalidMessage }
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= maximumLength * 6 + 1024 else { throw Failure.invalidMessage }
        let message = try JSONDecoder().decode(Message.self, from: data)
        guard message.version == 1,
              ["ready", "changed", "rendered", "failure"].contains(message.type)
        else { throw Failure.invalidMessage }
        if message.type == "changed" {
            guard let id = message.documentID, !id.isEmpty, id.utf16.count <= 512,
                  let generation = message.generation, UInt64(generation) != nil,
                  let revision = message.revision, revision > 0,
                  let markdown = message.markdown, markdown.utf16.count <= maximumLength
            else { throw Failure.invalidMessage }
        }
        return message
    }

    static func mutation(from previous: String, to next: String) -> SourceMutation? {
        guard !previous.utf8.elementsEqual(next.utf8) else { return nil }
        let old = Array(previous)
        let new = Array(next)
        var prefix = 0
        while prefix < min(old.count, new.count),
              String(old[prefix]).utf8.elementsEqual(String(new[prefix]).utf8) {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              String(old[old.count - suffix - 1]).utf8.elementsEqual(String(new[new.count - suffix - 1]).utf8) {
            suffix += 1
        }
        let expected = String(old[prefix..<(old.count - suffix)])
        let replacement = String(new[prefix..<(new.count - suffix)])
        return SourceMutation(
            range: NSRange(location: String(old[..<prefix]).utf16.count, length: expected.utf16.count),
            expected: expected, replacement: replacement
        )
    }

    enum Failure: LocalizedError {
        case invalidMessage
        case staleRevision
        case stopped

        var errorDescription: String? {
            switch self {
            case .invalidMessage: "The rich editor sent an invalid message. Your native source is unchanged."
            case .staleRevision: "The note changed before the rich edit arrived. Return to Edit before continuing."
            case .stopped: "The rich editor stopped. Return to Edit to recover the saved source."
            }
        }
    }
}
