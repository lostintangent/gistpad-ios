import Foundation

/// A GitHub identity: a gist's owner, and the GitHub side of your account.
public struct GitHubUser: Codable, Equatable, Sendable {
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

public struct GistRevision: Codable, Equatable, Sendable {
    public let version: String
}

public struct Gist: Codable, Equatable, Identifiable, Sendable {
    public internal(set) var id: String
    public internal(set) var description: String?
    public internal(set) var files: [String: File]
    public internal(set) var updatedAt: Date
    public internal(set) var createdAt: Date
    public internal(set) var isPublic: Bool
    public internal(set) var owner: GitHubUser?
    public internal(set) var truncated: Bool?
    public internal(set) var history: [GistRevision]?
    public internal(set) var commentCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, description, files, owner, truncated, history
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case isPublic = "public"
        case commentCount = "comments"
    }

    public var isDailyNote: Bool { description == DailyNote.gistDescription }
    public var isArchived: Bool {
        (description ?? "").range(of: #"\s*\[Archived\]$"#, options: .regularExpression) != nil
    }
    public var displayDescription: String {
        (description ?? "").replacingOccurrences(
            of: #"\s*\[Archived\]$"#, with: "", options: .regularExpression
        )
    }
    public var markdownFilenames: [String] { files.keys.filter { $0.hasSuffix(".md") }.sorted() }
    public var defaultMarkdownFilename: String? {
        if let dated = datedFiles {
            return dated.max { $0.value < $1.value }?.key
        }
        return files["README.md"] != nil ? "README.md" : markdownFilenames.first
    }
    private var datedFiles: [String: Date]? {
        let dated = markdownFilenames.filter { $0.lowercased() != "readme.md" }
        if !dated.isEmpty {
            for format in FilenameDateFormat.allCases {
                let values = dated.compactMap { name in
                    format.date(filename: name).map { (filename: name, date: $0) }
                }
                if values.count == dated.count {
                    return Dictionary(uniqueKeysWithValues: values)
                }
            }
        }
        return nil
    }
    public var displayName: String {
        let name = displayDescription.isEmpty
            ? (files.keys.sorted().first.map(Gist.File.displayName) ?? "Empty")
            : displayDescription
        return name == "README" ? "Untitled" : name
    }
    public var revision: String? { history?.first?.version }

    /// The gistpad.dev link that shares `filename`, or nil when the gist doesn't have that file.
    public func shareURL(filename: String) -> URL? {
        guard files[filename] != nil,
              let path = filename.addingPercentEncoding(withAllowedCharacters: Self.unreserved) else { return nil }
        return URL(string: "https://gistpad.dev/#/share/\(id)/\(path)")
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    func matchesWebMarkdownFilter(allowImages: Bool) -> Bool {
        files.values.allSatisfy {
            $0.language == "Markdown" || $0.filename.hasSuffix(".tldraw")
                || (allowImages && $0.filename.hasSuffix(".png"))
        }
    }
}

extension Gist {
    /// GitHub's data for one file in a gist. It never holds your edits.
    public struct File: Codable, Equatable, Sendable {
        public internal(set) var filename: String
        public internal(set) var language: String?
        public internal(set) var content: String?
        public internal(set) var truncated: Bool?
        public internal(set) var rawURL: URL?
        public internal(set) var size: Int?

        enum CodingKeys: String, CodingKey {
            case filename, language, content, truncated, size
            case rawURL = "raw_url"
        }
    }
}

enum FilenameDateFormat: CaseIterable {
    case isoDay, monthFirstDay, month, year

    func date(filename: String, timeZone: TimeZone = .gmt) -> Date? {
        let name = String(filename.dropLast(3))
        let pattern: String
        switch self {
        case .isoDay: pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#
        case .monthFirstDay: pattern = #"^[0-9]{2}-[0-9]{2}-[0-9]{4}$"#
        case .month: pattern = #"^[0-9]{4}-[0-9]{2}$"#
        case .year: pattern = #"^[0-9]{4}$"#
        }
        guard name.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let values = name.split(separator: "-").compactMap { Int($0) }
        let components: DateComponents
        switch self {
        case .isoDay: components = DateComponents(year: values[0], month: values[1], day: values[2])
        case .monthFirstDay:
            components = DateComponents(year: values[2], month: values[0], day: values[1])
        case .month: components = DateComponents(year: values[0], month: values[1], day: 1)
        case .year: components = DateComponents(year: values[0], month: 1, day: 1)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == components.year, actual.month == components.month,
              actual.day == components.day else { return nil }
        return date
    }
}

extension Gist.File {
    /// What GitHub stores for an empty file, since a gist can't hold one.
    public static let emptyContent = "\u{2064}"

    public static func decodeContent(_ content: String) -> String {
        content == emptyContent ? "" : content
    }

    public static func encodeContent(_ content: String) -> String {
        content.isEmpty ? emptyContent : content
    }

    public static func displayName(_ filename: String) -> String {
        filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
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
            try container.encode(Gist.File.encodeContent(content), forKey: .content)
        case .rename(let filename):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(filename, forKey: .filename)
        case .delete:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}
