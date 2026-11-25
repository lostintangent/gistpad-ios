import Foundation

public struct GistComment: Codable, Equatable, Identifiable, Sendable {
    public struct Author: Codable, Equatable, Sendable {
        public let id: Int64
        public let login: String
        public let avatarURL: URL?

        public init(id: Int64, login: String, avatarURL: URL? = nil) {
            self.id = id
            self.login = login
            self.avatarURL = avatarURL
        }

        enum CodingKeys: String, CodingKey {
            case id, login
            case avatarURL = "avatar_url"
        }
    }

    public let id: Int64
    public let body: String
    public let user: Author?
    public let createdAt: Date

    public init(
        id: Int64, body: String, user: Author?, createdAt: Date
    ) {
        self.id = id
        self.body = body
        self.user = user
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, body, user
        case createdAt = "created_at"
    }

    public var parsedBody: GistCommentBody { GistCommentBody(body) }

    public func canEdit(as userID: Int64) -> Bool { user?.id == userID }

    public func canDelete(as userID: Int64, gistOwnerID: Int64?) -> Bool {
        canEdit(as: userID) || gistOwnerID == userID
    }
}

/// A comment that quotes the file or replies to another comment starts with a blockquote line
/// (`> quoted text` or `> [comment:123]`). That line and the blank lines after it are its prefix,
/// which stays hidden while the comment is displayed or edited.
public struct GistCommentBody: Equatable, Sendable {
    /// The body GitHub stores, prefix included.
    public let markdown: String
    let prefix: String
    public let quote: String?
    let parentID: Int64?
    public let text: String

    init(_ body: String) {
        markdown = body
        let firstLine = String(String.UnicodeScalarView(body.unicodeScalars.prefix { $0 != "\n" }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard firstLine.hasPrefix(">"),
              let match = body.prefixMatch(
                of: #/[^\n]*(?:\n[^\S\n]*(?=\n|$))*\n?/#.matchingSemantics(.unicodeScalar))
        else {
            (prefix, quote, parentID, text) = ("", nil, nil, body)
            return
        }
        prefix = String(match.output)
        text = body[match.range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if let marker = firstLine.wholeMatch(of: #/>\s*\[comment:(\d+)\]\s*/#),
           let parentID = Int64(marker.output.1) {
            (self.parentID, quote) = (parentID, nil)
        } else {
            (parentID, quote) = (nil, firstLine.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// A new comment on a passage of the file.
    public init(quoting quote: String, text: String) {
        self.init("> \(quote)\n\n\(text)")
    }

    public init(replyingTo parentID: Int64, text: String) {
        self.init("> [comment:\(parentID)]\n\n\(text)")
    }

    /// The body after an edit to its text, keeping the hidden prefix.
    public func replacingText(with text: String) -> String { prefix + text }
}
