import Foundation

public struct GitHubUser: Codable, Equatable, Sendable {
    public let id: Int64
    public let login: String
    public let avatarURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, login
        case avatarURL = "avatar_url"
    }
}

public struct GistFile: Codable, Equatable, Sendable {
    public let filename: String
    public let language: String?
    public let content: String?
    public let truncated: Bool?
    public let rawURL: URL?
    public let size: Int?

    enum CodingKeys: String, CodingKey {
        case filename, language, content, truncated, size
        case rawURL = "raw_url"
    }
}

public struct GistRevision: Codable, Equatable, Sendable {
    public let version: String
}

public struct Gist: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let description: String?
    public let files: [String: GistFile]
    public let updatedAt: Date
    public let createdAt: Date
    public let isPublic: Bool
    public let owner: GitHubUser?
    public let truncated: Bool?
    public let history: [GistRevision]?

    enum CodingKeys: String, CodingKey {
        case id, description, files, owner, truncated, history
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case isPublic = "public"
    }

    public var isDailyNote: Bool { description == GistConventions.dailyNotesDescription }
    public var isArchived: Bool {
        (description ?? "").range(of: #"\s*\[Archived\]$"#, options: .regularExpression) != nil
    }
    public var displayDescription: String {
        (description ?? "").replacingOccurrences(
            of: #"\s*\[Archived\]$"#, with: "", options: .regularExpression
        )
    }
    public var markdownFilenames: [String] { files.keys.filter { $0.hasSuffix(".md") }.sorted() }
    public var displayName: String {
        let name = displayDescription.isEmpty
            ? (files.keys.sorted().first.map(GistConventions.fileDisplayName) ?? "Empty")
            : displayDescription
        return name == "README" ? "Untitled" : name
    }
    public var revision: String? { history?.first?.version }

    public func matchesWebMarkdownFilter(allowImages: Bool) -> Bool {
        files.values.allSatisfy {
            $0.language == "Markdown" || $0.filename.hasSuffix(".tldraw")
                || (allowImages && $0.filename.hasSuffix(".png"))
        }
    }
}

public enum GistConventions {
    public static let dailyNotesDescription = "\u{1F4C6} Daily notes"
    public static let templateFilename = "template.md"
    public static let emptyContent = "\u{2064}"

    public static func decodeContent(_ content: String) -> String {
        content == emptyContent ? "" : content
    }

    public static func encodeContent(_ content: String) -> String {
        content.isEmpty ? emptyContent : content
    }

    public static func fileDisplayName(_ filename: String) -> String {
        filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
    }

    public static func markdownFilename(_ name: String) -> String {
        name.hasSuffix(".md") ? name : name + ".md"
    }

    public static func todayFilename(date: Date = .now, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.md", parts.year!, parts.month!, parts.day!)
    }

    public static func dailyContent(template: String?, dateFilename: String) -> String {
        guard let template, !template.isEmpty else { return "# \(fileDisplayName(dateFilename))\n\n" }
        return decodeContent(template).replacingOccurrences(
            of: "{{date}}", with: fileDisplayName(dateFilename)
        )
    }

    public static func initialContent(description: String = "", content: String? = nil) -> String {
        content.flatMap { $0.isEmpty ? nil : $0 }
            ?? (description.isEmpty ? emptyContent : "# \(description)\n\n")
    }
}

public enum FileChange: Encodable, Sendable {
    case content(String)
    case rename(String)
    case delete

    enum CodingKeys: String, CodingKey { case content, filename }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .content(let content):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(GistConventions.encodeContent(content), forKey: .content)
        case .rename(let filename):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(filename, forKey: .filename)
        case .delete:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}
