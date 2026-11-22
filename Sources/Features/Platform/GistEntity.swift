import AppIntents
import Foundation

@AppEntity(schema: .notes.note)
public struct GistEntity: Codable, Identifiable, Sendable {
    public static let defaultQuery = GistEntityQuery()
    public var id: String { link.url.absoluteString }
    var title: String
    var excerpt: String?
    let tags: [String]
    let updatedAt: Date?
    public let link: GistPadLink
    public let accountID: UUID?
    var folderName: String?
    var body: String?
    var pinned: Bool?

    public var name: AttributedString { AttributedString(title) }
    public var content: AttributedString? { body.map(AttributedString.init) }
    public var attachments: [IntentFile] { [] }
    public var isPinned: Bool { pinned ?? false }
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

    /// A copy showing `body`, or no body when the open note's text isn't known.
    public func withBody(_ body: String?) -> Self {
        var entity = self
        entity.body = body
        if let body { entity.excerpt = LibrarySnapshot.excerpt(body) }
        return entity
    }

    public func withMetadata(name: String?, isPinned: Bool?) -> Self {
        var entity = withBody(nil)
        entity.title = name ?? title
        entity.folderName = name ?? folderName
        entity.pinned = isPinned ?? pinned
        return entity
    }

    /// The entity macro adds stored properties of its own, so encoding lists the ones GistPad keeps.
    private enum CodingKeys: String, CodingKey {
        case title, excerpt, tags, updatedAt, link, accountID, folderName, body, pinned
    }
}

public struct GistEntityQuery: EntityStringQuery {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Dependency var app: any PlatformActions
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [GistEntity] {
        try await app.noteEntities(for: identifiers)
    }

    public func suggestedEntities() async throws -> [GistEntity] {
        try await Array(notesSnapshot(validating: app)?.gists.prefix(12) ?? [])
    }

    public func entities(matching string: String) async throws -> [GistEntity] {
        let terms = string.split(whereSeparator: \.isWhitespace).map(String.init)
        return try await notesSnapshot(validating: app)?.gists.filter { gist in
            let content = ([gist.title] + gist.tags).joined(separator: " ")
            return terms.allSatisfy { content.localizedStandardContains($0) }
        } ?? []
    }
}
