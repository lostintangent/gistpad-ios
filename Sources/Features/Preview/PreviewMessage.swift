import Foundation
import Markdown

struct PreviewFile: Equatable, Sendable {
    let document: MarkdownDocument
    let allowsTaskEdits: Bool

    /// The page repeats the render's generation in every message it posts.
    func arguments(generation: UInt64) -> [String: Any] {
        ["generation": generation, "markdown": document.text, "allowsTaskEdits": allowsTaskEdits]
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
enum PreviewMessage {
    case ready
    case rendered
    case taskToggle(MarkdownEdit)
    case openWikilink(String)
    case openURL(URL)
    case commentActivate(segment: Int, start: Int, end: Int)
    case failure(String)

    private struct Envelope: Decodable {
        let type: String
        let generation: UInt64?
        let location: Int?
        let kind: String?
        let target: String?
        let message: String?
        let segment: Int?
        let start: Int?
        let end: Int?
    }

    /// Nil for a message from an earlier render.
    init?(_ body: Any, file: PreviewFile, generation: UInt64) throws {
        guard JSONSerialization.isValidJSONObject(body) else { throw PreviewError.invalidMessage }
        let message = try JSONDecoder().decode(Envelope.self, from: JSONSerialization.data(withJSONObject: body))
        if message.type == "ready" {
            self = .ready
            return
        }
        guard message.generation == generation else { return nil }
        switch message.type {
        case "taskToggle":
            // The page is the untrusted side, so it only names a box, and the document makes the edit.
            guard file.allowsTaskEdits, let location = message.location,
                  let edit = file.document.edit(togglingTaskAt: location) else {
                throw PreviewError.invalidMessage
            }
            self = .taskToggle(edit)
        case "link":
            guard let target = message.target, !target.isEmpty else { throw PreviewError.invalidMessage }
            switch message.kind {
            case "wikilink":
                self = .openWikilink(target)
            case "external":
                guard let url = URL(string: target),
                      let scheme = url.scheme?.lowercased(),
                      ["https", "http", "mailto"].contains(scheme),
                      url.user == nil, url.password == nil,
                      scheme == "mailto" || url.host != nil else {
                    throw PreviewError.invalidMessage
                }
                self = .openURL(url)
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
            self = .failure(message.message ?? "")
        default:
            throw PreviewError.invalidMessage
        }
    }
}
