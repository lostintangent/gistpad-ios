import Foundation
import SwiftData
import Testing
@testable import GistPadSync

@Suite struct SharedStoreTests {
    @Test func appGroupLocationAndInboxAreDurableWithAnAccountScopedImport() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let location = try SharedStoreLocation(containerURL: container)
        let store = try DraftStore.open(location: location)
        let account = UUID()
        let draft = try await store.newDraft(
            accountID: account, githubUserID: 42, text: "- [ ] Task"
        )
        let command = SharedDraftCommand(
            accountID: account, draftID: draft.id, expectedGeneration: 0,
            edit: DraftSourceEdit(location: 3, length: 1, expectedText: " ", replacement: "x")
        )
        let first = try SharedDraftInbox(location: location)
        let second = try SharedDraftInbox(location: location)
        try await first.enqueue(command)
        try await second.enqueue(command)
        #expect(try await second.pending(accountID: account).count == 1)
        #expect(try await second.pending(accountID: UUID()).isEmpty)
        let changed = try await store.apply(command)
        #expect(changed.text == "- [x] Task")
        #expect(changed.generation == 1)
        #expect(changed.state == .savedLocally)
        let reopened = try DraftStore.open(location: location)
        let replay = try await reopened.apply(command)
        #expect(replay.text == "- [x] Task")
        #expect(replay.generation == 1)
        try await second.acknowledge(command)
        #expect(try await first.pending(accountID: account).isEmpty)
    }

    @Test func reusedCommandIDsCannotReplacePreviouslyEnqueuedOrAppliedCommands() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let location = try SharedStoreLocation(containerURL: container)
        let inbox = try SharedDraftInbox(location: location)
        let store = try DraftStore.open(location: location)
        let account = UUID()
        let draft = try await store.newDraft(accountID: account, githubUserID: 42, text: "abc")
        let id = UUID()
        let one = SharedDraftCommand(
            id: id, accountID: account, draftID: draft.id, expectedGeneration: 0,
            edit: DraftSourceEdit(location: 0, length: 1, expectedText: "a", replacement: "A")
        )
        let two = SharedDraftCommand(
            id: id, accountID: account, draftID: draft.id, expectedGeneration: 0,
            edit: DraftSourceEdit(location: 0, length: 1, expectedText: "a", replacement: "Z")
        )
        try await inbox.enqueue(one)
        await #expect(throws: SharedStoreError.duplicateCommand) { try await inbox.enqueue(two) }
        await #expect(throws: SharedStoreError.duplicateCommand) { try await inbox.acknowledge(two) }
        _ = try await store.apply(one)
        await #expect(throws: SharedStoreError.duplicateCommand) { try await store.apply(two) }
        #expect(try await store.draft(id: draft.id, accountID: account).text == "Abc")
    }

    @Test func invalidUTF16OffsetsAndStaleGenerationsNeverMutateTheDraft() async throws {
        let store = try DraftStore.open(inMemory: true)
        let account = UUID()
        let text = "\u{1F642} - [ ] Task"
        let draft = try await store.newDraft(accountID: account, githubUserID: 42, text: text)
        let splitSurrogate = SharedDraftCommand(
            accountID: account, draftID: draft.id, expectedGeneration: 0,
            edit: DraftSourceEdit(location: 1, length: 0, expectedText: "", replacement: "broken")
        )
        await #expect(throws: SharedStoreError.invalidCommand) { try await store.apply(splitSurrogate) }
        let stale = SharedDraftCommand(
            accountID: account, draftID: draft.id, expectedGeneration: 3,
            edit: DraftSourceEdit(location: 6, length: 1, expectedText: " ", replacement: "x")
        )
        await #expect(throws: DraftError.staleGeneration) { try await store.apply(stale) }
        #expect(try await store.draft(id: draft.id, accountID: account).text == text)
    }

    @Test func concurrentInboxPublishersExposeOnlyCompleteCommands() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let location = try SharedStoreLocation(containerURL: container)
        let account = UUID()
        let commands = (0..<24).map { index in
            SharedDraftCommand(
                accountID: account, draftID: UUID(), expectedGeneration: UInt64(index),
                edit: DraftSourceEdit(location: 0, length: 0, expectedText: "", replacement: "Command \(index)")
            )
        }
        let observer = try SharedDraftInbox(location: location)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for command in commands {
                group.addTask {
                    let publisher = try SharedDraftInbox(location: location)
                    try await publisher.enqueue(command)
                    try await publisher.enqueue(command)
                    let visible = try await observer.pending(accountID: account)
                    #expect(Set(visible.map(\.id)).isSubset(of: Set(commands.map(\.id))))
                }
            }
            try await group.waitForAll()
        }
        let visible = try await observer.pending(accountID: account)
        #expect(Set(visible.map(\.id)) == Set(commands.map(\.id)))
        #expect(visible.count == commands.count)
    }

    @Test func inboxImportsFollowDocumentGenerationsRatherThanRandomUUIDOrder() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let location = try SharedStoreLocation(containerURL: container)
        let inbox = try SharedDraftInbox(location: location)
        let store = try DraftStore.open(location: location)
        let account = UUID()
        let draft = try await store.newDraft(accountID: account, githubUserID: 42, text: "abc")
        let first = SharedDraftCommand(
            id: try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")),
            accountID: account, draftID: draft.id, expectedGeneration: 0,
            edit: DraftSourceEdit(location: 0, length: 1, expectedText: "a", replacement: "A")
        )
        let second = SharedDraftCommand(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000")),
            accountID: account, draftID: draft.id, expectedGeneration: 1,
            edit: DraftSourceEdit(location: 1, length: 1, expectedText: "b", replacement: "B")
        )
        try await inbox.enqueue(second)
        try await inbox.enqueue(first)
        for command in try await inbox.pending(accountID: account) {
            _ = try await store.apply(command)
            try await inbox.acknowledge(command)
        }
        #expect(try await store.draft(id: draft.id, accountID: account).text == "ABc")
    }

    @Test func aBrokenEnvelopeCannotBeIgnoredOrBlockADifferentAccount() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let location = try SharedStoreLocation(containerURL: container)
        let inbox = try SharedDraftInbox(location: location)
        let account = UUID()
        let command = SharedDraftCommand(
            accountID: account, draftID: UUID(), expectedGeneration: 0,
            edit: DraftSourceEdit(location: 0, length: 0, expectedText: "", replacement: "")
        )
        try await inbox.enqueue(command)
        let url = location.inboxURL.appendingPathComponent(account.uuidString, isDirectory: true)
            .appendingPathComponent("\(command.id.uuidString).json")
        try Data("broken envelope".utf8).write(to: url)
        #expect(try await inbox.pending(accountID: UUID()).isEmpty)
        await #expect(throws: DecodingError.self) { try await inbox.pending(accountID: account) }
    }

    @Test func schemaExpansionKeepsDraftsAndDropsRetiredRecoveryRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let account = UUID()
        let id = UUID()
        do {
            let schema = Schema([Build16Schema.StoredDraft.self, Build16Schema.StoredRecovery.self])
            let configuration = ModelConfiguration("GistPadDrafts", schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let draft = Build16Schema.StoredDraft(
                id: id, accountID: account, githubUserID: 42, gistID: "abc123",
                filename: "README.md", description: "Note", text: "unsynced source",
                baseContent: "remote base", baseRevision: "one",
                stateData: try JSONEncoder().encode(SaveState.savedLocally)
            )
            draft.generation = 7
            draft.autosavePaused = true
            context.insert(draft)
            context.insert(Build16Schema.StoredRecovery(
                draft: draft, sent: "older source", generation: 6, remote: "remote base"
            ))
            try context.save()
        }
        let upgraded = try DraftStore.open(url: url)
        let draft = try await upgraded.draft(id: id, accountID: account)
        #expect(draft.text == "unsynced source")
        #expect(draft.generation == 7)
        #expect(draft.state == .savedLocally)
        #expect(draft.baseContent == "remote base")
        try await upgraded.cacheLibrary(
            owned: [], starred: [], preferences: Preferences(metadata: [:]), accountID: account
        )
        let command = SharedDraftCommand(
            accountID: account, draftID: id, expectedGeneration: 7,
            edit: DraftSourceEdit(location: 0, length: 8, expectedText: "unsynced", replacement: "accepted")
        )
        #expect(try await upgraded.apply(command).text == "accepted source")
        #expect(try await upgraded.cachedLibrary(accountID: account) != nil)
    }
}

// Build 16's persisted schema. It exists only so the test can prove that stores written before the
// recovery and autosave-pause removal still open with their drafts intact.
enum Build16Schema {
    @Model
    final class StoredDraft {
        @Attribute(.unique) var id: UUID
        var accountID: UUID
        var githubUserID: Int64
        var gistID: String?
        var filename: String
        var gistDescription: String
        var text: String
        var generation: UInt64
        var baseContent: String?
        var baseRevision: String?
        var attemptedContent: String?
        var attemptedGeneration: UInt64?
        var autosavePaused: Bool = false
        var stateData: Data
        var updatedAt: Date? = nil

        init(
            id: UUID, accountID: UUID, githubUserID: Int64, gistID: String?,
            filename: String, description: String, text: String, baseContent: String?,
            baseRevision: String?, stateData: Data
        ) {
            self.id = id
            self.accountID = accountID
            self.githubUserID = githubUserID
            self.gistID = gistID
            self.filename = filename
            gistDescription = description
            self.text = text
            generation = 0
            self.baseContent = baseContent
            self.baseRevision = baseRevision
            self.stateData = stateData
            updatedAt = .now
        }
    }

    @Model
    final class StoredRecovery {
        @Attribute(.unique) var id: UUID
        var accountID: UUID
        var draftID: UUID
        var createdAt: Date
        var base: String?
        var local: String
        var remote: String?
        var sent: String
        var generation: UInt64

        init(draft: StoredDraft, sent: String, generation: UInt64, remote: String?) {
            id = UUID()
            accountID = draft.accountID
            draftID = draft.id
            createdAt = .now
            base = draft.baseContent
            local = draft.text
            self.remote = remote
            self.sent = sent
            self.generation = generation
        }
    }
}
