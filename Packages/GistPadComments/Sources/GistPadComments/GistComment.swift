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

    public static func latestVersions(in comments: [GistComment]) -> [GistComment] {
        var latest: [Int64: GistComment] = [:]
        var order: [Int64] = []
        for comment in comments {
            if let previous = latest[comment.id] {
                if comment.updatedAt > previous.updatedAt { latest[comment.id] = comment }
            } else {
                latest[comment.id] = comment
                order.append(comment.id)
            }
        }
        return order.map { latest[$0]! }
    }

    public func canEdit(as userID: Int64?) -> Bool {
        guard let userID else { return false }
        return user?.id == userID
    }

    public func canDelete(as userID: Int64?, gistOwnerID: Int64?) -> Bool {
        guard let userID else { return false }
        return canEdit(as: userID) || gistOwnerID == userID
    }
}

public enum GistCommentBodyError: Error, Equatable, Sendable {
    case invalidParentID
}

public struct GistCommentBody: Equatable, Sendable {
    public let prefix: String
    public let quote: String?
    public let parentID: Int64?
    public let text: String
    public var isReply: Bool { quote == nil && !prefix.isEmpty }

    public init(_ body: String) {
        let units = Array(body.utf16)
        let lineEnd = units.firstIndex(of: 10) ?? units.count
        let firstLine = Self.trim(String(decoding: units[..<lineEnd], as: UTF16.self))
        guard firstLine.hasPrefix(">") else {
            prefix = ""
            quote = nil
            parentID = nil
            text = body
            return
        }

        var end = lineEnd
        while end < units.count, units[end] == 10 {
            var next = end + 1
            while next < units.count, units[next] != 10, Self.isWebWhitespace(units[next]) {
                next += 1
            }
            if next == units.count || units[next] == 10 {
                end = next
            } else {
                end += 1
                break
            }
        }
        prefix = String(decoding: units[..<end], as: UTF16.self)
        text = Self.trim(String(decoding: units[end...], as: UTF16.self))
        let quoted = Self.trim(String(firstLine.dropFirst()))
        if quoted.hasPrefix("[comment:"), quoted.hasSuffix("]") {
            let value = quoted.dropFirst(9).dropLast()
            if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) {
                parentID = Int64(value)
                quote = nil
                return
            }
        }
        parentID = nil
        quote = quoted
    }

    public func replacingText(with text: String) -> String { prefix + text }

    public static func quoting(_ quote: String, text: String) -> String {
        "> \(quote)\n\n\(text)"
    }

    public static func replying(to parentID: Int64, text: String) throws -> String {
        guard parentID > 0 else { throw GistCommentBodyError.invalidParentID }
        return "> [comment:\(parentID)]\n\n\(text)"
    }

    static func trim(_ value: String) -> String {
        let units = Array(value.utf16)
        let start = units.firstIndex(where: { !isWebWhitespace($0) }) ?? units.count
        let end = units.lastIndex(where: { !isWebWhitespace($0) }).map { $0 + 1 } ?? start
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    private static func isWebWhitespace(_ unit: UInt16) -> Bool {
        // ECMAScript trim/\s includes BOM, but not ICU's extra U+0085 whitespace.
        (9...13).contains(unit) || unit == 32 || unit == 160 || unit == 5760
            || (8192...8202).contains(unit) || unit == 8232 || unit == 8233
            || unit == 8239 || unit == 8287 || unit == 12288 || unit == 65279
    }
}
