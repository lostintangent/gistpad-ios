import AppIntents
import Foundation
#if os(iOS)
import CoreSpotlight
import UniformTypeIdentifiers
#endif

@AppEntity(schema: .notes.note)
public struct GistEntity: Codable, Equatable, Identifiable, Sendable {
    public static let defaultQuery = GistEntityQuery()
    public var id: String { link.url.absoluteString }
    let title: String
    let excerpt: String?
    let tags: [String]
    let updatedAt: Date?
    public let link: GistPadLink
    public let accountID: UUID?
    let folderName: String?
    let body: String?
    let pinned: Bool?

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

    public func withBody(_ body: String) -> Self {
        Self(
            title: title, excerpt: LibrarySnapshot.excerpt(body), tags: tags, updatedAt: updatedAt,
            link: link, accountID: accountID, folderName: folderName, body: body, pinned: pinned)
    }

    public func withoutBody() -> Self {
        Self(
            title: title, excerpt: excerpt, tags: tags, updatedAt: updatedAt,
            link: link, accountID: accountID, folderName: folderName, body: nil, pinned: pinned)
    }

    public func withMetadata(name: String?, isPinned: Bool?) -> Self {
        Self(
            title: name ?? title, excerpt: excerpt, tags: tags, updatedAt: updatedAt,
            link: link, accountID: accountID, folderName: name ?? folderName, body: nil,
            pinned: isPinned ?? pinned)
    }
}

extension GistEntity {
    private enum CodingKeys: String, CodingKey {
        case title, excerpt, tags, updatedAt, link, accountID, folderName, body, pinned
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        excerpt = try values.decodeIfPresent(String.self, forKey: .excerpt)
        tags = try values.decode([String].self, forKey: .tags)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt)
        link = try values.decode(GistPadLink.self, forKey: .link)
        accountID = try values.decodeIfPresent(UUID.self, forKey: .accountID)
        folderName = try values.decodeIfPresent(String.self, forKey: .folderName)
        body = try values.decodeIfPresent(String.self, forKey: .body)
        pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(title, forKey: .title)
        try values.encodeIfPresent(excerpt, forKey: .excerpt)
        try values.encode(tags, forKey: .tags)
        try values.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try values.encode(link, forKey: .link)
        try values.encodeIfPresent(accountID, forKey: .accountID)
        try values.encodeIfPresent(folderName, forKey: .folderName)
        try values.encodeIfPresent(body, forKey: .body)
        try values.encodeIfPresent(pinned, forKey: .pinned)
    }

    public static func == (left: Self, right: Self) -> Bool {
        left.title == right.title && left.excerpt == right.excerpt
            && left.tags == right.tags && left.updatedAt == right.updatedAt
            && left.link == right.link && left.accountID == right.accountID
            && left.folderName == right.folderName && left.body == right.body
            && left.pinned == right.pinned
    }
}

public struct GistEntityQuery: EntityStringQuery {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Dependency private var dailyNotes: any DailyNoteActions
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [GistEntity] {
        try await dailyNotes.noteEntities(for: identifiers)
    }

    public func suggestedEntities() async throws -> [GistEntity] {
        try await Array(currentSnapshot()?.gists.prefix(12) ?? [])
    }

    public func entities(matching string: String) async throws -> [GistEntity] {
        let terms = string.split(whereSeparator: \.isWhitespace).map(String.init)
        return try await currentSnapshot()?.gists.filter { gist in
            let content = ([gist.title] + gist.tags).joined(separator: " ")
            return terms.allSatisfy { content.localizedStandardContains($0) }
        } ?? []
    }

    private func currentSnapshot() async throws -> LibrarySnapshot? {
        try await notesSnapshot(validating: dailyNotes)
    }
}

#if os(iOS)
extension GistEntity: IndexedEntity {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Gist")

    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.displayName = title
        attributes.contentDescription = excerpt
        attributes.keywords = tags
        attributes.contentModificationDate = updatedAt
        attributes.contentURL = link.url
        return attributes
    }
}

extension GistEntityQuery: IndexedEntityQuery {
    public func reindexEntities(
        for identifiers: [String], indexDescription: CSSearchableIndexDescription
    ) async throws {
        let notes = try await currentSnapshot()?.gists.filter { identifiers.contains($0.id) } ?? []
        try await GistSpotlightIndex.index.indexAppEntities(notes)
    }

    public func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await GistSpotlightIndex.index.indexAppEntities(currentSnapshot()?.gists ?? [])
    }

}

public actor GistSpotlightIndex {
    /// The gists Spotlight may hold, or nil when only clearing it is safe.
    private var indexedIDs: Set<String>?
    /// Spotlight keeps this index across updates, so it keeps its first name.
    static var index: CSSearchableIndex {
        CSSearchableIndex(name: "GistPadNotes", protectionClass: .complete)
    }

    /// Spotlight still holds the gists of the snapshot GistPad launched with, so launch deletes
    /// just the ones that went away instead of clearing the index.
    public init(launchedWith snapshot: LibrarySnapshot?) {
        indexedIDs = snapshot.map { Set($0.gists.map(\.id)) }
    }

    /// Brings Spotlight to `current`. Callers update one snapshot at a time.
    public func update(_ current: LibrarySnapshot) async throws {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let currentIDs = Set(current.gists.map(\.id))
        if let indexedIDs {
            let removed = indexedIDs.subtracting(currentIDs)
            if !removed.isEmpty {
                try await Self.index.deleteAppEntities(
                    identifiedBy: Array(removed), ofType: GistEntity.self)
            }
        } else {
            try await Self.index.deleteAllSearchableItems()
        }
        // Spotlight now holds no gist outside this snapshot, even if indexing stops partway.
        indexedIDs = currentIDs
        try await Self.index.indexAppEntities(current.gists)
    }
}

public struct OpenGistIntent: OpenIntent {
    public static let title: LocalizedStringResource = "Open Gist"
    public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Gist") public var target: GistEntity
    public init() {}
    public init(target: GistEntity) { self.target = target }

    @MainActor
    public func perform() async throws -> some IntentResult {
        PendingLink.shared.link = target.link
        return .result()
    }
}

public struct OpenTodayIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Today"
    public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        PendingLink.shared.link = .today
        return .result()
    }
}

public struct NewGistIntent: AppIntent {
    public static let title: LocalizedStringResource = "New Gist"
    public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        PendingLink.shared.link = .newGist
        return .result()
    }
}

public struct GistPadPlatformIntents: AppIntentsPackage {}
#endif
