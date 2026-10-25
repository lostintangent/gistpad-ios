import Foundation
import GistPadComments

public actor CommentConversationDiskStore: CommentConversationStore {
    private let directory: URL
    private let files = FileManager.default
    private var deletedScopes: Set<CommentConversationScope> = []

    public init(directory: URL) {
        self.directory = directory
    }

    public static func applicationStore() throws -> CommentConversationDiskStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return CommentConversationDiskStore(
            directory: support.appendingPathComponent("GistPadComments", isDirectory: true))
    }

    public func loadDrafts(scope: CommentConversationScope) throws -> CommentDraftArchive? {
        let url = try location(scope: scope, name: "drafts")
        guard let data = try read(url) else { return nil }
        let archive = try JSONDecoder().decode(CommentDraftArchive.self, from: data)
        try validate(archive, scope: scope)
        return archive
    }

    public func removeDrafts(scope: CommentConversationScope) throws {
        let url = try location(scope: scope, name: "drafts")
        deletedScopes.insert(scope)
        do { try files.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }

    private func validate(_ archive: CommentDraftArchive, scope: CommentConversationScope) throws {
        guard archive.scope == scope, archive.revision < UInt64.max,
              archive.drafts.contains(where: { $0.id == archive.activeDraftID }),
              Set(archive.drafts.map(\.id)).count == archive.drafts.count,
              Set(archive.drafts.map(\.target.storageKey)).count == archive.drafts.count,
              archive.drafts.allSatisfy({ $0.generation < UInt64.max }) else {
            throw CommentStoreFailure.invalidRecord
        }
    }

    public func saveDrafts(_ archive: CommentDraftArchive) throws {
        guard !deletedScopes.contains(archive.scope) else { throw CommentStoreFailure.unavailable }
        try validate(archive, scope: archive.scope)
        if let previous = try loadDrafts(scope: archive.scope) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let differs = try encoder.encode(previous) != encoder.encode(archive)
            if previous.revision > archive.revision
                || (previous.revision == archive.revision && differs) {
                throw CommentStoreFailure.staleWrite
            }
        }
        try write(archive, scope: archive.scope, name: "drafts")
    }

    private func location(scope: CommentConversationScope, name: String) throws -> URL {
        guard !scope.gistID.isEmpty,
              scope.gistID.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
              }) else { throw CommentStoreFailure.invalidRecord }
        return directory
            .appendingPathComponent(scope.accountID.uuidString, isDirectory: true)
            .appendingPathComponent(scope.gistID, isDirectory: true)
            .appendingPathComponent("\(name).json")
    }

    private func read(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private func write(_ value: some Encodable, scope: CommentConversationScope, name: String) throws {
        let url = try location(scope: scope, name: name)
        let parent = url.deletingLastPathComponent()
        #if os(iOS)
        try files.createDirectory(
            at: parent, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        for folder in [directory, parent.deletingLastPathComponent(), parent] {
            try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: folder.path)
        }
        let options: Data.WritingOptions = [.atomic, .completeFileProtection]
        #else
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let options: Data.WritingOptions = [.atomic]
        #endif
        try JSONEncoder().encode(value).write(to: url, options: options)
    }
}
