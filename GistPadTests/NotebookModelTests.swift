import Foundation
import GistPadInterface
import GistPadSync
import Testing
@testable import GistPad

@MainActor
struct NotebookModelTests {
    @Test func mapsOwnedStarredAndWebMetadataWithoutDuplicates() throws {
        let owned = try makeGist(id: "a", title: "A note")
        let starred = try makeGist(id: "b", title: "A shared note", owner: "someone")
        let snapshot = NotebookModel.librarySnapshot(
            owned: [owned], starred: [owned, starred], account: fixtureAccount
        )
        #expect(snapshot.notes.count == 2)
        let note = try #require(snapshot.notes.first { $0.id == "a" })
        #expect(note.isOwned)
        #expect(note.isStarred)
        #expect(note.isPinned)
        #expect(note.isSecret)
        #expect(note.tagIDs == ["ideas"])
        #expect(snapshot.tags == [.init(id: "ideas", name: "Ideas", colorHex: "#EBC85A")])
        #expect(snapshot.notes.first { $0.id == "b" }?.isOwned == false)
    }

    @Test func refreshDoesNotReplaceAnOpenedDocumentOrFilters() async throws {
        let original = try makeGist(id: "a", title: "Original", content: "Original text")
        let provider = StubNotebookProvider(account: fixtureAccount, gists: [original])
        let model = NotebookModel(provider: provider)
        await model.start()
        await model.open(gistID: "a")
        model.library.query = "Original"
        model.library.selectedTagIDs = ["ideas"]
        await provider.setGists([try makeGist(id: "a", title: "Changed remotely", content: "Remote text")])
        await model.refresh()
        #expect(model.library.snapshot.notes.first?.title == "Changed remotely")
        #expect(model.loadedDocument?.text == "Original text")
        #expect(model.library.query == "Original")
        #expect(model.library.selectedTagIDs == ["ideas"])
        #expect(model.library.openDocumentOutsideFilter?.id == "a")
    }

    @Test func anOlderOpenCannotReplaceTheNewerSelection() async throws {
        let provider = StubNotebookProvider(
            account: fixtureAccount,
            gists: [try makeGist(id: "a", title: "First"), try makeGist(id: "b", title: "Second")]
        )
        let model = NotebookModel(provider: provider)
        await model.start()
        await provider.holdRead(id: "a")
        let firstOpen = Task { await model.open(gistID: "a") }
        await provider.waitForHeldRead()
        await model.open(gistID: "b")
        await provider.releaseRead()
        await firstOpen.value
        #expect(model.loadedDocument?.gist.id == "b")
        #expect(model.library.selectedNoteID == "b")
        #expect(!model.isOpeningDocument)
    }

    @Test func networkFailureKeepsExistingLibraryAndDocument() async throws {
        let provider = StubNotebookProvider(
            account: fixtureAccount, gists: [try makeGist(id: "a", title: "A note")]
        )
        let model = NotebookModel(provider: provider)
        await model.start()
        await model.open(gistID: "a")
        await provider.failRequests()
        await model.refresh()
        #expect(model.library.snapshot.notes.count == 1)
        #expect(model.loadedDocument?.gist.id == "a")
        guard case .failed(let message) = model.library.loadState else {
            Issue.record("A failed refresh must remain visible.")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test func accountSwitchWaitsForLocalWorkDisposition() async throws {
        let provider = StubNotebookProvider(
            account: fixtureAccount, gists: [try makeGist(id: "a", title: "A note")]
        )
        let model = NotebookModel(provider: provider)
        await model.start()
        await model.open(gistID: "a")
        let replacement = NotebookAccount(id: UUID(), login: "another-person", preferences: .init(metadata: [:]))
        await provider.setSignInAccount(replacement)
        await model.signIn()
        #expect(model.account?.id == fixtureAccount.id)
        #expect(model.pendingAccount?.id == replacement.id)
        #expect(model.loadedDocument?.accountID == fixtureAccount.id)
        guard case .reconnectRequired = model.library.loadState else {
            Issue.record("An account switch must not silently adopt another account.")
            return
        }
    }

    @Test func uncertainCreatesAndReconnectsCannotPublish() {
        #expect(NotebookModel.interfaceSaveState(.savedLocally) == .savedLocally)
        #expect(NotebookModel.interfaceSaveState(.savedToGitHub) == .savedToGitHub)
        #expect(NotebookModel.interfaceSaveState(.reconnect) == .reconnectRequired)
        let uncertain = NotebookModel.interfaceSaveState(.failed(.creationUncertain))
        #expect(uncertain == .creationUncertain)
        #expect(!uncertain.canPublish)
        #expect(!NotebookModel.interfaceSaveState(.failed(.incompleteRemote)).canPublish)
        #expect(!NotebookModel.interfaceSaveState(.failed(.readOnly)).canPublish)
    }
}

private let fixtureAccount = NotebookAccount(
    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
    login: "notebook-owner",
    preferences: .init(metadata: [
        "pinnedGists": .array([.string("a")]),
        "tags": .object(["ideas": .object(["name": .string("Ideas"), "color": .string("#EBC85A")])]),
        "gistTags": .object(["a": .array([.string("ideas")])])
    ])
)

private func makeGist(id: String, title: String, content: String = "Synthetic text", owner: String = "notebook-owner") throws -> Gist {
    let json: [String: Any] = [
        "id": id, "description": title, "public": false,
        "updated_at": "2026-10-24T00:00:00Z", "created_at": "2026-10-23T00:00:00Z",
        "owner": ["id": 1, "login": owner],
        "files": ["README.md": ["filename": "README.md", "language": "Markdown", "content": content]],
        "history": [["version": "synthetic-revision"]]
    ]
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Gist.self, from: JSONSerialization.data(withJSONObject: json))
}

private actor StubNotebookProvider: NotebookProviding {
    let account: NotebookAccount
    var signInAccount: NotebookAccount
    var notes: [Gist]
    var shouldFail = false
    var heldID: String?
    var heldRead: CheckedContinuation<Void, Never>?
    var readObserver: CheckedContinuation<Void, Never>?

    init(account: NotebookAccount, gists: [Gist]) {
        self.account = account
        self.signInAccount = account
        self.notes = gists
    }

    func cachedAccount() -> NotebookAccount? { account }
    func signIn() -> NotebookAccount { signInAccount }
    func refreshAccount() throws -> NotebookAccount {
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return account
    }
    func gists(accountID: UUID) -> [Gist] { notes }
    func starredGists(accountID: UUID) -> [Gist] { [] }
    func gist(id: String, accountID: UUID) async throws -> Gist {
        if id == heldID {
            await withCheckedContinuation { continuation in
                heldRead = continuation
                readObserver?.resume()
                readObserver = nil
            }
        }
        guard let gist = notes.first(where: { $0.id == id }) else { throw GitHubClientError.missingFile }
        return gist
    }
    func content(gist: Gist, filename: String, accountID: UUID) throws -> String {
        guard let content = gist.files[filename]?.content else { throw GitHubClientError.missingFile }
        return GistConventions.decodeContent(content)
    }
    func openDraft(for document: NotebookDocument) throws -> DraftSnapshot { throw DraftError.notFound }
    func persist(draftID: UUID, accountID: UUID, text: String, generation: UInt64) throws -> DraftSnapshot {
        throw DraftError.notFound
    }
    func publish(draftID: UUID, accountID: UUID) throws -> DraftSnapshot { throw DraftError.notFound }
    func setGists(_ gists: [Gist]) { notes = gists }
    func failRequests() { shouldFail = true }
    func setSignInAccount(_ account: NotebookAccount) { signInAccount = account }
    func holdRead(id: String) { heldID = id }
    func waitForHeldRead() async {
        if heldRead != nil { return }
        await withCheckedContinuation { readObserver = $0 }
    }
    func releaseRead() {
        heldRead?.resume()
        heldRead = nil
        heldID = nil
    }
}
