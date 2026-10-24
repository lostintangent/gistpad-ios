import Foundation
import Testing
@testable import GistPadSync

@Suite struct BlankDraftTests {
    @Test(arguments: ["", " \t\r\n\u{2003}"])
    func discardsOnlyTheExpectedBlankGeneration(text: String) async throws {
        let store = try DraftStore.open(inMemory: true)
        let account = UUID()
        let draft = try await store.newDraft(accountID: account, githubUserID: 42, text: text)
        #expect(draft.isDiscardableBlank)
        #expect(try await store.discardBlankDraft(
            id: draft.id, accountID: account, expectedGeneration: draft.generation
        ))
        #expect(try await store.drafts(accountID: account).isEmpty)
        #expect(try await !store.discardBlankDraft(
            id: draft.id, accountID: account, expectedGeneration: draft.generation
        ))
    }

    @Test(arguments: ["An accepted thought", "\u{2064}", "👩🏽‍💻", "\u{200B}"])
    func preservesEveryNonwhitespaceSource(text: String) async throws {
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.newDraft(accountID: UUID(), githubUserID: 42, text: text)
        #expect(!draft.isDiscardableBlank)
        #expect(try await !store.discardBlankDraft(
            id: draft.id, accountID: draft.accountID, expectedGeneration: draft.generation
        ))
        #expect(try await store.draft(id: draft.id, accountID: draft.accountID) == draft)
    }

    @Test func keepsTitlesBoundNotesAndStaleGenerations() async throws {
        let store = try DraftStore.open(inMemory: true)
        let account = UUID()
        let titled = try await store.newDraft(
            accountID: account, githubUserID: 42, description: "A title"
        )
        let bound = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "existing", filename: "README.md",
            description: "", content: "", revision: "one"
        )
        let changed = try await store.newDraft(accountID: account, githubUserID: 42)
        _ = try await store.persist(
            id: changed.id, accountID: account, text: "Keep this", generation: 1
        )
        for draft in [titled, bound, changed] {
            #expect(try await !store.discardBlankDraft(
                id: draft.id, accountID: account, expectedGeneration: draft.generation
            ))
        }
        #expect(try await store.draft(id: changed.id, accountID: account).text == "Keep this")
        await #expect(throws: DraftError.accountMismatch) {
            try await store.discardBlankDraft(
                id: changed.id, accountID: UUID(), expectedGeneration: 1
            )
        }
        _ = try await store.persist(id: changed.id, accountID: account, text: " ", generation: 2)
        #expect(try await !store.discardBlankDraft(
            id: changed.id, accountID: account, expectedGeneration: 1
        ))
        #expect(try await store.discardBlankDraft(
            id: changed.id, accountID: account, expectedGeneration: 2
        ))
    }

    @Test func preservesUncertainCreationHistoryAndPendingPhotos() async throws {
        let store = try DraftStore.open(inMemory: true)
        let account = UUID()
        let uncertain = try await store.newDraft(accountID: account, githubUserID: 42)
        try await store.beginAttempt(
            id: uncertain.id, accountID: account, content: "", generation: 0, remote: nil
        )
        try await store.setState(.failed(.creationUncertain), id: uncertain.id, accountID: account)
        let historical = try await store.newDraft(accountID: account, githubUserID: 42)
        try await store.beginAttempt(
            id: historical.id, accountID: account, content: "Recover this", generation: 0, remote: nil
        )
        try await store.clearAttempt(id: historical.id, accountID: account)
        let photo = try await store.newDraft(accountID: account, githubUserID: 42)
        _ = try await store.enqueueImage(
            pngData: testPNG(), draftID: photo.id, accountID: account,
            expectedGeneration: 0, insertionLocation: 0
        )
        for draft in [uncertain, historical, photo] {
            #expect(try await !store.discardBlankDraft(
                id: draft.id, accountID: account, expectedGeneration: draft.generation
            ))
        }
        #expect(try await store.recoveries(id: historical.id, accountID: account).first?.sent == "Recover this")
        #expect(try await store.imageUploads(accountID: account).count == 1)
    }

    @Test func blankCleanupCommitsAcrossStoreReopeningWithoutChangingOtherSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let account = UUID()
        let store = try DraftStore.open(url: url)
        let blank = try await store.newDraft(accountID: account, githubUserID: 42)
        let text = "Keep e\u{301}\r\n日本語 👩🏽‍💻"
        let kept = try await store.newDraft(accountID: account, githubUserID: 42, text: text)
        let reopened = try DraftStore.open(url: url)
        #expect(try await reopened.discardBlankDraft(
            id: blank.id, accountID: account, expectedGeneration: 0
        ))
        let final = try DraftStore.open(url: url)
        let remaining = try await final.drafts(accountID: account)
        #expect(remaining.map(\.id) == [kept.id])
        #expect(remaining.first?.text.utf8.elementsEqual(text.utf8) == true)
    }
}
