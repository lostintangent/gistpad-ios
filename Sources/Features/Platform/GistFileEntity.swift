import AppIntents
import Foundation
import Markdown

@AppEntity(schema: .notes.note)
public struct GistFileEntity: Codable {
    /// Its first name, which keeps saved Shortcuts and Spotlight items working.
    public static let persistentIdentifier = "GistEntity"
    public static let defaultQuery = GistFileQuery()
    public var id: String { link.url.absoluteString }
    var title: String
    var excerpt: String?
    let tags: [String]
    var updatedAt: Date
    public let link: GistPadLink
    public let accountID: UUID?
    var folderName: String?
    var body: String?
    // Platform gap: Swift 6.4.2 crashes compiling this entity when it stores isPinned itself.
    // Remove pinned and store isPinned, coded as "pinned", when the compiler handles it.
    var pinned = false

    public var name: AttributedString { AttributedString(title) }
    public var content: AttributedString? { body.map(AttributedString.init) }
    public var attachments: [IntentFile] { [] }
    public var isPinned: Bool { pinned }
    public var creationDate: Date? { nil }
    public var modificationDate: Date? { updatedAt }
    public var folder: GistFolderEntity? {
        guard case .gist(let id, _) = link, let folderName else { return nil }
        return GistFolderEntity(id: id, name: folderName, accountID: accountID)
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)", subtitle: excerpt.map { "\($0)" },
            image: .init(systemName: "doc.text"))
    }

    /// A copy showing `document`'s body, or no body when the open note's text isn't known.
    public func withBody(of document: MarkdownDocument?) -> Self {
        var entity = self
        entity.body = document?.body
        if let document { entity.excerpt = document.excerpt }
        return entity
    }

    public func withMetadata(name: String?, isPinned: Bool?) -> Self {
        var entity = withBody(of: nil)
        entity.title = name ?? title
        entity.folderName = name ?? folderName
        entity.pinned = isPinned ?? pinned
        return entity
    }

    // Platform gap: @AppEntity's EntityProperty storage isn't Codable, so encoding lists the fields
    // GistPad keeps. Remove CodingKeys when the macro keeps its storage out of Codable.
    private enum CodingKeys: String, CodingKey {
        case title, excerpt, tags, updatedAt, link, accountID, folderName, body, pinned
    }
}

public struct GistFileQuery: EntityStringQuery {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Dependency var app: any PlatformActions
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [GistFileEntity] {
        try await app.noteEntities(for: identifiers)
    }

    public func suggestedEntities() async throws -> [GistFileEntity] {
        try await Array(LibrarySnapshot.read(validating: app)?.files.prefix(12) ?? [])
    }

    public func entities(matching string: String) async throws -> [GistFileEntity] {
        let terms = string.split(whereSeparator: \.isWhitespace).map(String.init)
        return try await LibrarySnapshot.read(validating: app)?.files.filter { file in
            let content = ([file.title] + file.tags).joined(separator: " ")
            return terms.allSatisfy { content.localizedStandardContains($0) }
        } ?? []
    }
}
