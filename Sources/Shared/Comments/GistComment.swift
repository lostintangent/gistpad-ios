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
    public let updatedAt: Date

    public init(
        id: Int64, body: String, user: Author?, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.body = body
        self.user = user
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, body, user
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public var parsedBody: GistCommentBody { GistCommentBody(body) }

    public func canEdit(as userID: Int64?) -> Bool {
        guard let userID else { return false }
        return user?.id == userID
    }

    public func canDelete(as userID: Int64?, gistOwnerID: Int64?) -> Bool {
        guard let userID else { return false }
        return canEdit(as: userID) || gistOwnerID == userID
    }
}

/// A comment that quotes the file or replies to another comment starts with a blockquote line
/// (`> quoted text` or `> [comment:123]`). That line and the blank lines after it are its prefix,
/// which stays hidden while the comment is displayed or edited.
public struct GistCommentBody: Equatable, Sendable {
    public let prefix: String
    public let quote: String?
    public let parentID: Int64?
    public let text: String

    public init(_ body: String) {
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

    public func replacingText(with text: String) -> String { prefix + text }

    public static func quoting(_ quote: String, text: String) -> String {
        "> \(quote)\n\n\(text)"
    }

    public static func replying(to parentID: Int64, text: String) -> String {
        "> [comment:\(parentID)]\n\n\(text)"
    }
}
