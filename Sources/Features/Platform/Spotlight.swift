#if os(iOS)
import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers

extension GistFileEntity: IndexedEntity {
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

extension GistFileQuery: IndexedEntityQuery {
    public func reindexEntities(
        for identifiers: [String], indexDescription: CSSearchableIndexDescription
    ) async throws {
        let notes = try await LibrarySnapshot.read(validating: app)?.files ?? []
        try await SpotlightIndex.index.indexAppEntities(notes.filter { identifiers.contains($0.id) })
    }

    public func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await SpotlightIndex.index.indexAppEntities(LibrarySnapshot.read(validating: app)?.files ?? [])
    }
}

// Platform gap: Spotlight can't list the files it holds or replace them as one set, so this tracks
// them itself. Remove indexedIDs when CSSearchableIndex can replace all of a type's entities.
public actor SpotlightIndex {
    /// The files Spotlight may hold, or nil when only clearing it is safe.
    private var indexedIDs: Set<String>?
    /// Spotlight keeps this index across updates, so it keeps its first name.
    static var index: CSSearchableIndex {
        CSSearchableIndex(name: "GistPadNotes", protectionClass: .complete)
    }

    /// Spotlight still holds the files of the snapshot GistPad launched with, so launch deletes
    /// just the ones that went away instead of clearing the index.
    public init(launchedWith snapshot: LibrarySnapshot?) {
        indexedIDs = snapshot.map { Set($0.files.map(\.id)) }
    }

    /// Brings Spotlight to `current`. Callers update one snapshot at a time.
    public func update(_ current: LibrarySnapshot) async throws {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let currentIDs = Set(current.files.map(\.id))
        if let indexedIDs {
            let removed = indexedIDs.subtracting(currentIDs)
            if !removed.isEmpty {
                try await Self.index.deleteAppEntities(
                    identifiedBy: Array(removed), ofType: GistFileEntity.self)
            }
        } else {
            try await Self.index.deleteAllSearchableItems()
        }
        // Spotlight now holds no file outside this snapshot, even if indexing stops partway.
        indexedIDs = currentIDs
        try await Self.index.indexAppEntities(current.files)
    }
}
#endif
