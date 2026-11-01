import Foundation
import SwiftData
import Testing
@testable import GistPadSync

@Suite struct DraftMetadataTests {
    @Test func metadataEditTimesRecognizeByteDistinctUnicodeFilenames() async throws {
        let store = try DraftStore.open(inMemory: true)
        let account = UUID()
        let original = try await store.newDraft(
            accountID: account, githubUserID: 42, filename: "Caf\u{e9}.md", text: "note")
        let renamed = try await store.updateDraftMetadata(
            id: original.id, accountID: account, expectedFilename: original.filename,
            filename: "Cafe\u{301}.md", description: original.description)
        #expect(renamed.filename.utf8.elementsEqual("Cafe\u{301}.md".utf8))
        #expect(renamed.updatedAt != original.updatedAt)
        let unchanged = try await store.updateDraftMetadata(
            id: renamed.id, accountID: account, expectedFilename: renamed.filename,
            filename: renamed.filename, description: renamed.description)
        #expect(unchanged.updatedAt == renamed.updatedAt)
    }

    @Test func legacyUnknownEditTimesAreNotReplacedByReadOrRefreshTimes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let store = try DraftStore.open(url: url)
        let account = UUID()
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "legacy", filename: "README.md",
            description: "Legacy copy", content: "base", revision: "one")
        let context = ModelContext(store.modelContainer)
        let record = try #require(context.fetch(FetchDescriptor<StoredDraft>()).first)
        record.updatedAt = nil
        try context.save()
        let reopened = try DraftStore.open(url: url)
        #expect(try await reopened.draft(id: draft.id, accountID: account).updatedAt == nil)
        let refreshed = try await reopened.refreshCleanDraft(
            id: draft.id, accountID: account, expectedGeneration: 0,
            content: "remote change", revision: "two")
        guard case .refreshed(let refreshedDraft) = refreshed else {
            Issue.record("Expected the legacy copy to refresh without a fabricated local edit.")
            return
        }
        #expect(refreshedDraft.updatedAt == nil)
        #expect(try await reopened.persist(
            id: draft.id, accountID: account, text: "a local edit",
            generation: refreshedDraft.generation + 1).updatedAt != nil)
    }

    @Test func draftEditTimeSurvivesReadsPublicationAndReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let store = try DraftStore.open(url: url)
        let account = UUID()
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Note", content: "base", revision: "one")
        let edited = try await store.persist(id: draft.id, accountID: account, text: "edit", generation: 1)
        #expect(edited.updatedAt != nil)
        #expect(edited.updatedAt != draft.updatedAt)
        let same = try await store.persist(id: draft.id, accountID: account, text: "edit", generation: 1)
        #expect(same.updatedAt == edited.updatedAt)
        try await store.beginAttempt(
            id: draft.id, accountID: account, content: "edit", generation: 1, remote: "base")
        let published = try await store.acknowledge(
            id: draft.id, accountID: account, gistID: "abc123", content: "edit",
            revision: "two", generation: 1)
        #expect(published.updatedAt == edited.updatedAt)
        #expect(try await DraftStore.open(url: url).draft(
            id: draft.id, accountID: account).updatedAt == edited.updatedAt)
    }

    @Test func cleanLocalDiscardPreservesUnpublishedBytesUncertaintyAndPendingImages() async throws {
        let store = try DraftStore.open(inMemory: true)
        let account = UUID()
        func make(_ gistID: String) async throws -> DraftSnapshot {
            try await store.openDraft(
                accountID: account, githubUserID: 42, gistID: gistID, filename: "README.md",
                description: "Note", content: "Cafe\u{301}", revision: "one")
        }
        let clean = try await make("clean")
        try await store.beginAttempt(
            id: clean.id, accountID: account, content: clean.text, generation: 0, remote: clean.text)
        _ = try await store.acknowledge(
            id: clean.id, accountID: account, gistID: "clean", content: clean.text,
            revision: "two", generation: 0)
        #expect(try await store.discardLocalCopy(
            id: clean.id, accountID: account, expectedGeneration: 0, onlyIfClean: true))
        let dirty = try await make("dirty")
        _ = try await store.persist(id: dirty.id, accountID: account, text: "Caf\u{e9}", generation: 1)
        #expect(!(try await store.discardLocalCopy(
            id: dirty.id, accountID: account, expectedGeneration: 1, onlyIfClean: true)))
        let uncertain = try await make("uncertain")
        try await store.beginAttempt(
            id: uncertain.id, accountID: account, content: uncertain.text, generation: 0, remote: uncertain.text)
        try await store.setState(.failed(.publicationUncertain), id: uncertain.id, accountID: account)
        #expect(!(try await store.discardLocalCopy(
            id: uncertain.id, accountID: account, expectedGeneration: 0, onlyIfClean: true)))
        let image = try await make("image")
        _ = try await store.enqueueImage(
            pngData: testPNG(), draftID: image.id, accountID: account,
            expectedGeneration: 0, insertionLocation: 0)
        #expect(!(try await store.discardLocalCopy(
            id: image.id, accountID: account, expectedGeneration: 0, onlyIfClean: true)))
        #expect(try await store.drafts(accountID: account).count == 3)
    }

    @Test func neverPublishedDraftsCanBeDiscardedButAmbiguousCreationCannot() async throws {
        let store = try DraftStore.open(inMemory: true)
        let account = UUID()
        let local = try await store.newDraft(
            accountID: account, githubUserID: 42, text: "Only on this iPhone")
        _ = try await store.persist(
            id: local.id, accountID: account, text: "Edited only on this iPhone", generation: 1)
        #expect(try await store.discardLocalCopy(
            id: local.id, accountID: account, expectedGeneration: 1))
        #expect(try await store.drafts(accountID: account).allSatisfy { $0.id != local.id })

        let uncertain = try await store.newDraft(
            accountID: account, githubUserID: 42, text: "Maybe on GitHub")
        try await store.beginAttempt(
            id: uncertain.id, accountID: account, content: uncertain.text, generation: 0, remote: nil)
        try await store.setState(.failed(.creationUncertain), id: uncertain.id, accountID: account)
        await #expect(throws: DraftError.ambiguousCreation) {
            try await store.discardLocalCopy(id: uncertain.id, accountID: account, expectedGeneration: 0)
        }
        try await store.discardUncertainCreation(
            id: uncertain.id, accountID: account, expectedGeneration: 0)
        #expect(try await store.drafts(accountID: account).allSatisfy { $0.id != uncertain.id })
    }

    @Test func explicitLocalDiscardRemovesOnlyTheConfirmedDraftAndItsLinkedBytes() async throws {
        let store = try DraftStore.open(inMemory: true)
        let account = UUID()
        let first = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "gone", filename: "One.md",
            description: "Gone", content: "base", revision: "one")
        let second = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "gone", filename: "Two.md",
            description: "Gone", content: "other file", revision: "one")
        _ = try await store.persist(id: first.id, accountID: account, text: "unpublished", generation: 1)
        try await store.beginAttempt(
            id: first.id, accountID: account, content: "unpublished", generation: 1, remote: "base")
        try await store.setState(.failed(.publicationUncertain), id: first.id, accountID: account)
        _ = try await store.enqueueImage(
            pngData: testPNG(), draftID: first.id, accountID: account,
            expectedGeneration: 1, insertionLocation: 0)
        await #expect(throws: DraftError.staleGeneration) {
            try await store.discardLocalCopy(id: first.id, accountID: account, expectedGeneration: 0)
        }
        await #expect(throws: DraftError.accountMismatch) {
            try await store.discardLocalCopy(id: first.id, accountID: UUID(), expectedGeneration: 1)
        }
        #expect(try await store.discardLocalCopy(
            id: first.id, accountID: account, expectedGeneration: 1))
        #expect(try await store.drafts(accountID: account).map(\.id) == [second.id])
        #expect(try await store.imageUploads(accountID: account).isEmpty)
        let context = ModelContext(store.modelContainer)
        #expect(try context.fetchCount(FetchDescriptor<StoredRecovery>()) == 0)
    }

    @Test func metadataChangesRetainSourceGenerationAndRecoveryHistory() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
            description: "Before", content: "base", revision: "one"
        )
        _ = try await store.persist(id: draft.id, accountID: account, text: "local", generation: 1)
        try await store.beginAttempt(id: draft.id, accountID: account, content: "local", generation: 1, remote: "base")
        await #expect(throws: DraftMetadataError.publicationPending) {
            try await store.updateDraftMetadata(
                id: draft.id, accountID: account, expectedFilename: "README.md", filename: "New.md", description: "After"
            )
        }
        try await store.clearAttempt(id: draft.id, accountID: account)
        let before = try await store.draft(id: draft.id, accountID: account)
        let changed = try await store.updateDraftMetadata(
            id: draft.id, accountID: account, expectedFilename: "README.md", filename: "New.md", description: "After"
        )
        #expect(changed.id == before.id)
        #expect(changed.filename == "New.md")
        #expect(changed.description == "After")
        #expect(changed.text == before.text)
        #expect(changed.generation == before.generation)
        #expect(changed.baseContent == before.baseContent)
        #expect(changed.baseRevision == before.baseRevision)
        #expect(changed.state == before.state)
        #expect(try await store.recoveries(id: draft.id, accountID: account).first?.local == "local")
        #expect(try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "New.md",
            description: "After", content: "remote", revision: "two"
        ).id == draft.id)
    }

    @Test func metadataGuardsPreventCollisionStaleResponsesAndAccountLeakage() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let one = try await store.newFileDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "One.md", description: "", text: "one"
        )
        _ = try await store.newFileDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: "Two.md", description: "", text: "two"
        )
        await #expect(throws: DraftMetadataError.filenameInUse) {
            try await store.updateDraftMetadata(
                id: one.id, accountID: account, expectedFilename: "One.md", filename: "Two.md", description: ""
            )
        }
        await #expect(throws: DraftMetadataError.staleMetadata) {
            try await store.updateDraftMetadata(
                id: one.id, accountID: account, expectedFilename: "Gone.md", filename: "Three.md", description: ""
            )
        }
        await #expect(throws: DraftError.accountMismatch) {
            try await store.updateDraftMetadata(
                id: one.id, accountID: UUID(), expectedFilename: "One.md", filename: "Three.md", description: ""
            )
        }
        for filename in ["", "folder/file.md", "bad\nname.md"] {
            await #expect(throws: DraftMetadataError.invalidFilename) {
                try await store.updateDraftMetadata(
                    id: one.id, accountID: account, expectedFilename: "One.md", filename: filename, description: ""
                )
            }
        }
        #expect(try await store.draft(id: one.id, accountID: account).filename == "One.md")
    }

    @Test func confirmedDeletionPurgesDirtyDraftsHistoryImagesReceiptsAndCachedContent() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        func open(_ filename: String, accountID: UUID) async throws -> DraftSnapshot {
            try await store.openDraft(
                accountID: accountID, githubUserID: 42, gistID: "abc123", filename: filename,
                description: "", content: "base", revision: "one"
            )
        }
        let clean = try await open("Clean.md", accountID: account)
        let dirty = try await open("Dirty.md", accountID: account)
        _ = try await store.persist(id: dirty.id, accountID: account, text: "unsynced", generation: 1)
        let historical = try await open("History.md", accountID: account)
        try await store.beginAttempt(
            id: historical.id, accountID: account, content: "base", generation: 0, remote: "base"
        )
        _ = try await store.acknowledge(
            id: historical.id, accountID: account, gistID: "abc123", content: "base", revision: "two", generation: 0
        )
        let foreign = try await open("Foreign.md", accountID: UUID())
        try await store.beginAttempt(
            id: foreign.id, accountID: foreign.accountID, content: "base", generation: 0, remote: "base")
        _ = try await store.acknowledge(
            id: foreign.id, accountID: foreign.accountID, gistID: "abc123",
            content: "base", revision: "two", generation: 0)
        let kept = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "other", filename: "README.md",
            description: "Keep", content: "untouched", revision: "one")
        let command = SharedDraftCommand(
            accountID: account, draftID: dirty.id, expectedGeneration: 1,
            edit: .init(location: 0, length: 0, expectedText: "", replacement: "new "))
        _ = try await store.apply(command)
        let image = try await store.enqueueImage(
            pngData: testPNG(), draftID: dirty.id, accountID: account,
            expectedGeneration: 2, insertionLocation: 0)
        let keptCommand = SharedDraftCommand(
            accountID: account, draftID: kept.id, expectedGeneration: 0,
            edit: .init(location: 0, length: 0, expectedText: "", replacement: "kept "))
        _ = try await store.apply(keptCommand)
        let keptImage = try await store.enqueueImage(
            pngData: testPNG(), draftID: kept.id, accountID: account,
            expectedGeneration: 1, insertionLocation: 0)
        let gist = try decodeGist(gistData())
        let otherGist = try decodeGist(gistData(id: "other", content: "untouched"))
        try await store.cacheLibrary(
            owned: [gist, otherGist], starred: [gist], preferences: .init(metadata: [:]), accountID: account)
        try await store.cacheGist(gist, accountID: account)
        try await store.cacheGist(otherGist, accountID: account)
        try await store.cacheContent("cached source", gist: gist, filename: "README.md", accountID: account)
        try await store.cacheContent("untouched", gist: otherGist, filename: "README.md", accountID: account)
        try await store.cacheLibrary(
            owned: [gist], starred: [gist], preferences: .init(metadata: [:]), accountID: foreign.accountID)
        let result = try await store.removeDraftsForDeletedGist(gistID: "abc123", accountID: account)
        #expect(result.removedDraftIDs == [clean.id, dirty.id, historical.id])
        #expect(try await store.drafts(accountID: account).map(\.id) == [kept.id])
        #expect(try await store.draft(id: foreign.id, accountID: foreign.accountID).text == "base")
        #expect(try await store.imageUploads(accountID: account).map(\.id) == [keptImage.id])
        #expect(try await store.recoveries(id: foreign.id, accountID: foreign.accountID).count == 1)
        #expect(try await store.apply(keptCommand).generation == 1)
        #expect(try await store.cachedLibrary(accountID: foreign.accountID)?.owned.map(\.id) == ["abc123"])
        let cached = try #require(await store.cachedLibrary(accountID: account))
        #expect(cached.owned.map(\.id) == ["other"])
        #expect(cached.starred.isEmpty)
        #expect(cached.details["abc123"] == nil)
        #expect(cached.details["other"] != nil)
        #expect(cached.fileContent.map(\.key) == ["other/README.md"])
        let context = ModelContext(store.modelContainer)
        #expect(try context.fetchCount(FetchDescriptor<StoredRecovery>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<StoredCommandReceipt>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<StoredImageUpload>()) == 1)
        await #expect(throws: ImageUploadError.notFound) {
            try await store.imageUpload(id: image.id, accountID: account)
        }
        await #expect(throws: DraftError.notFound) {
            try await store.draft(id: clean.id, accountID: account)
        }
    }
}
