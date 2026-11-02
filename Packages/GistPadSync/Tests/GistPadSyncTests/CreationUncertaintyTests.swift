import Foundation
import SwiftData
import Synchronization
import Testing
@testable import GistPadSync

@Suite struct CreationUncertaintyTests {
    @Test func explicitNewCreationKeepsTheDraftAndPublishesExactlyOnce() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let text = "# Deliberate new note\r\n日本語 e\u{301}\r\n"
        let draft = try await uncertainDraft(store: store, account: account, text: text)
        let allowed = try await store.confirmNewCreation(
            id: draft.id, accountID: account, expectedGeneration: 0)
        #expect(allowed.id == draft.id)
        #expect(allowed.text.utf8.elementsEqual(text.utf8))
        #expect(allowed.generation == 0)
        #expect(allowed.gistID == nil)
        #expect(allowed.state == .savedLocally)
        #expect(allowed.attemptedGeneration == nil)
        #expect(allowed.attemptedContent == nil)
        await #expect(throws: DraftError.ambiguousCreation) {
            try await store.confirmNewCreation(
                id: draft.id, accountID: account, expectedGeneration: 0)
        }
        let methods = Mutex<[String]>([])
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            methods.withLock { $0.append(request.httpMethod ?? "") }
            #expect(request.httpMethod == "POST")
            return FakeResponse(data: try gistData(content: text))
        }) { "fake" }
        let coordinator = SyncCoordinator(client: client, store: store)
        let published = try await coordinator.publish(id: draft.id, accountID: account)
        #expect(published.id == draft.id)
        #expect(published.state == .savedToGitHub)
        #expect(published.text.utf8.elementsEqual(text.utf8))
        #expect(try await store.drafts(accountID: account).count == 1)
        #expect(methods.withLock { $0 } == ["POST"])
    }

    @Test(arguments: [false, true])
    func resolutionRejectsStaleGenerationWrongAccountAndNonUncertainDrafts(discard: Bool) async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await uncertainDraft(store: store, account: account, text: "local")
        _ = try await store.persist(id: draft.id, accountID: account, text: "newer", generation: 1)
        await #expect(throws: DraftError.staleGeneration) {
            try await resolve(store: store, id: draft.id, account: account, generation: 0, discard: discard)
        }
        await #expect(throws: DraftError.accountMismatch) {
            try await resolve(store: store, id: draft.id, account: UUID(), generation: 1, discard: discard)
        }
        let ordinary = try await store.newDraft(accountID: account, githubUserID: 42, text: "ordinary")
        await #expect(throws: DraftError.ambiguousCreation) {
            try await resolve(store: store, id: ordinary.id, account: account, generation: 0, discard: discard)
        }
        #expect(try await store.draft(id: draft.id, accountID: account).text == "newer")
        #expect(try await store.draft(id: draft.id, accountID: account).attemptedGeneration == 0)
        #expect(try await store.drafts(accountID: account).count == 2)
    }

    @Test func discardRemovesOnlyTheChosenLocalCopyPhotosHistoryAndReceipts() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.newDraft(accountID: account, githubUserID: 42, text: "local")
        let command = SharedDraftCommand(
            accountID: account, draftID: draft.id, expectedGeneration: 0,
            edit: .init(location: 5, length: 0, expectedText: "", replacement: " appended"))
        let edited = try await store.apply(command)
        let image = try await store.enqueueImage(
            pngData: testPNG(), draftID: draft.id, accountID: account,
            expectedGeneration: 1, insertionLocation: 0)
        try await store.beginAttempt(
            id: draft.id, accountID: account, content: edited.text, generation: 1)
        try await store.setState(.failed(.creationUncertain), id: draft.id, accountID: account)
        let other = try await uncertainDraft(store: store, account: account, text: "keep this")
        let otherImage = try await store.enqueueImage(
            pngData: testPNG(), draftID: other.id, accountID: account,
            expectedGeneration: 0, insertionLocation: 0)
        try await store.discardUncertainCreation(id: draft.id, accountID: account, expectedGeneration: 1)
        #expect(try await store.drafts(accountID: account).map(\.id) == [other.id])
        #expect(try await store.imageUploads(accountID: account).map(\.id) == [otherImage.id])
        await #expect(throws: ImageUploadError.notFound) {
            try await store.imageUpload(id: image.id, accountID: account)
        }
        #expect(try await store.draft(id: other.id, accountID: account).text == "keep this")
        let context = ModelContext(store.modelContainer)
        #expect(try context.fetchCount(FetchDescriptor<StoredCommandReceipt>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<StoredDraft>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<StoredImageUpload>()) == 1)
    }

    private func uncertainDraft(store: DraftStore, account: UUID, text: String) async throws -> DraftSnapshot {
        let draft = try await store.newDraft(accountID: account, githubUserID: 42, text: text)
        try await store.beginAttempt(id: draft.id, accountID: account, content: text, generation: 0)
        try await store.setState(.failed(.creationUncertain), id: draft.id, accountID: account)
        return try await store.draft(id: draft.id, accountID: account)
    }

    private func resolve(
        store: DraftStore, id: UUID, account: UUID, generation: UInt64, discard: Bool
    ) async throws {
        if discard {
            try await store.discardUncertainCreation(id: id, accountID: account, expectedGeneration: generation)
        } else {
            _ = try await store.confirmNewCreation(id: id, accountID: account, expectedGeneration: generation)
        }
    }
}
