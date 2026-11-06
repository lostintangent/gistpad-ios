import Foundation
import Synchronization
import Testing
@testable import Sync

/// The publish rules: every keystroke is saved on the phone, publishing reaches GitHub once, and edits on
/// both sides become a conflict that shows the diff.
@Suite struct SyncTests {
    @Test func durableDraftSurvivesContainerReopenAndIsAccountIsolated() async throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fixture = try SyncFixture(store: DraftStore.open(url: url))
        let gist = fixture.server.addGist(description: "Note", files: ["README.md": "base"])
        let text = "Emoji \u{1F9D1}\u{200D}\u{1F4BB}\n日本語\nمرحبا"
        let draft = try await fixture.type(text, in: fixture.open(gist))

        let reopened = try DraftStore.open(url: url)
        let restored = try await reopened.draft(id: draft.id, accountID: SyncFixture.account)
        #expect(restored.text.utf8.elementsEqual(text.utf8))
        #expect(restored.generation == 1)
        #expect(restored.state == .savedLocally)
        #expect(try await reopened.drafts(accountID: UUID()).isEmpty)
        await #expect(throws: DraftError.accountMismatch) {
            try await reopened.draft(id: draft.id, accountID: UUID())
        }
    }

    @Test func openAdoptsCleanRemoteTextAndLeavesEditedFilesAlone() async throws {
        let fixture = try SyncFixture()
        let gist = fixture.server.addGist(description: "Note", files: ["README.md": "one"])
        let draft = try await fixture.open(gist)
        fixture.server.edit(gist.id, files: ["README.md": "two"])

        let adopted = try await fixture.inspect(draft)
        #expect(adopted.text == "two")
        #expect(adopted.baseContent == "two")
        #expect(adopted.generation == 1)
        #expect(adopted.state == .savedToGitHub)

        let edited = try await fixture.type("mine", in: adopted)
        let kept = try await fixture.store.refreshCleanDraft(
            id: draft.id, accountID: SyncFixture.account, expectedGeneration: edited.generation,
            content: "three", revision: "later")
        #expect(kept.text == "mine")
        #expect(kept.baseContent == "two")
        #expect(fixture.count("PATCH /gists/\(gist.id)") == 0)
    }

    enum RemoteChange: CaseIterable { case edited, addedOnTheWeb, deleted }

    @Test(arguments: RemoteChange.allCases)
    func aRemoteChangeUnderLocalEditsBecomesAConflictThatSurvivesRelaunch(_ change: RemoteChange) async throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fixture = try SyncFixture(store: DraftStore.open(url: url))
        let gist = fixture.server.addGist(
            description: "Note", files: ["README.md": "base", "2026-10-23.md": "# Other day"])
        let filename = change == .addedOnTheWeb ? "2026-10-24.md" : "README.md"
        let draft = try await fixture.type("local", in: fixture.open(gist, filename))
        let remote: String? = switch change {
        case .edited: "remote"
        case .addedOnTheWeb: "# Written on the web"
        case .deleted: nil
        }
        fixture.server.edit(gist.id, files: [filename: remote])

        let published = try await fixture.publish(draft)
        guard case .conflict(let conflict) = published.state else {
            Issue.record("Expected a conflict, got \(published.state)")
            return
        }
        #expect(conflict.base == (change == .addedOnTheWeb ? nil : "base"))
        #expect(conflict.local == "local")
        #expect(conflict.remote == remote)
        #expect(fixture.count("PATCH /gists/\(gist.id)") == 0)

        let relaunched = try await DraftStore.open(url: url).draft(id: draft.id, accountID: SyncFixture.account)
        #expect(relaunched.text == "local")
        #expect(relaunched.state == published.state)
    }

    @Test(arguments: [true, false])
    func resolvingAConflictPublishesTheChosenText(keepingMine: Bool) async throws {
        let fixture = try SyncFixture()
        let gist = fixture.server.addGist(description: "Note", files: ["README.md": "base"])
        let draft = try await fixture.type("mine", in: fixture.open(gist))
        fixture.server.edit(gist.id, files: ["README.md": "theirs"])
        let conflicted = try await fixture.publish(draft)

        let resolved = try await fixture.store.resolveConflict(
            id: draft.id, accountID: SyncFixture.account, expectedGeneration: conflicted.generation,
            text: keepingMine ? "mine" : "theirs",
            generation: keepingMine ? conflicted.generation : conflicted.generation + 1)
        #expect(resolved.baseContent == "theirs")
        #expect(resolved.state == .savedLocally)
        #expect(resolved.generation == (keepingMine ? 1 : 2))

        let published = try await fixture.publish(resolved)
        #expect(published.state == .savedToGitHub)
        #expect(fixture.remote(gist.id) == (keepingMine ? "mine" : "theirs"))
        #expect(fixture.count("PATCH /gists/\(gist.id)") == (keepingMine ? 1 : 0))
    }

    @Test func typingDuringAPublishIsNeverLost() async throws {
        let fixture = try SyncFixture()
        let gist = fixture.server.addGist(description: "Note", files: ["README.md": "base"])
        let gate = Gate()
        fixture.server.intercept { request in
            if request.httpMethod == "PATCH" { await gate.pass() }
            return nil
        }
        let first = try await fixture.type("first", in: fixture.open(gist))
        let publishing = Task { try await fixture.publish(first) }
        await gate.waitForArrival()
        let newer = try await fixture.type("first and newer", in: first)
        let staleAutosave = Task {
            try await fixture.publisher.publish(
                id: first.id, accountID: SyncFixture.account, reason: .autosave,
                expectedGeneration: first.generation)
        }
        await gate.release()
        await #expect(throws: CancellationError.self) { try await staleAutosave.value }

        let acknowledged = try await publishing.value
        #expect(acknowledged.text == "first and newer")
        #expect(acknowledged.generation == newer.generation)
        #expect(acknowledged.baseContent == "first")
        #expect(acknowledged.state == .savedLocally)
        #expect(fixture.remote(gist.id) == "first")

        #expect(try await fixture.publish(acknowledged).state == .savedToGitHub)
        #expect(fixture.remote(gist.id) == "first and newer")
        #expect(fixture.count("PATCH /gists/\(gist.id)") == 2)
    }

    @Test(arguments: [true, false])
    func aCutOffPublishFinishesWithoutWritingTwice(landed: Bool) async throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fixture = try SyncFixture(store: DraftStore.open(url: url))
        let gist = fixture.server.addGist(description: "Note", files: ["README.md": "base"])
        let cutOff = Mutex(true)
        let session = fixture.server.session
        fixture.server.intercept { request in
            guard request.httpMethod == "PATCH", cutOff.withLock({ first in
                defer { first = false }
                return first
            }) else { return nil }
            if landed { _ = try await session.data(for: request) }
            throw URLError(.networkConnectionLost)
        }
        let draft = try await fixture.type("local", in: fixture.open(gist))
        await #expect(throws: URLError.self) { try await fixture.publish(draft) }
        let interrupted = try await fixture.reload(draft)
        #expect(interrupted.state == .failed(.network))
        #expect(interrupted.attemptedContent == "local")

        let relaunched = try SyncFixture(store: DraftStore.open(url: url), server: fixture.server)
        let finished = try await relaunched.publish(draft)
        #expect(finished.state == .savedToGitHub)
        #expect(finished.attemptedContent == nil)
        #expect(finished.baseContent == "local")
        #expect(fixture.remote(gist.id) == "local")
        #expect(fixture.count("PATCH /gists/\(gist.id)") == 1)
    }

    @Test func typingAfterACutOffPublishIsSavedOnThisIPhoneUntilThePublishLands() async throws {
        let fixture = try SyncFixture()
        let gist = fixture.server.addGist(description: "Note", files: ["README.md": "base"])
        let session = fixture.server.session
        let cutOff = Mutex(true)
        fixture.server.intercept { request in
            guard request.httpMethod == "PATCH", cutOff.withLock({ first in
                defer { first = false }
                return first
            }) else { return nil }
            _ = try await session.data(for: request)
            throw URLError(.networkConnectionLost)
        }
        let sent = try await fixture.type("local", in: fixture.open(gist))
        await #expect(throws: URLError.self) { try await fixture.publish(sent) }
        #expect(try await fixture.reload(sent).state == .failed(.network))

        // GitHub has "local" now, so going back to the old text isn't saved there.
        let undone = try await fixture.type("base", in: fixture.reload(sent))
        #expect(undone.state == .savedLocally, "Typing lets autosave publish again.")
        #expect(undone.attemptedContent == "local")

        let published = try await fixture.publish(undone)
        #expect(published.state == .savedToGitHub)
        #expect(fixture.remote(gist.id) == "base")
    }

    @Test(arguments: [true, false], [false, true])
    func aCutOffCreateFindsItsGistInsteadOfPostingTwice(landed: Bool, daily: Bool) async throws {
        let fixture = try SyncFixture()
        try await fixture.store.cacheLibrary(
            owned: [], starred: [], preferences: .init(metadata: [:]), accountID: SyncFixture.account)
        if !daily {
            // Same title, file and size, but other text, so only the bytes tell them apart.
            fixture.server.addGist(description: "Ideas", files: ["README.md": "# Ideas\n\nOlder"])
        }
        let cutOff = Mutex(true)
        let session = fixture.server.session
        fixture.server.intercept { request in
            guard request.httpMethod == "POST", cutOff.withLock({ first in
                defer { first = false }
                return first
            }) else { return nil }
            if landed { _ = try await session.data(for: request) }
            throw URLError(.timedOut)
        }
        let draft = if daily {
            try await DailyNotes(
                accountID: SyncFixture.account, githubUserID: SyncFixture.user, client: fixture.github,
                store: fixture.store, publisher: fixture.publisher
            ).stageToday(target: DailyNote.Day(date: .now, timeZone: .gmt)).draft
        } else {
            try await fixture.store.newDraft(
                accountID: SyncFixture.account, githubUserID: SyncFixture.user, description: "Ideas",
                text: "# Ideas\n\nFirst")
        }
        await #expect(throws: URLError.self) { try await fixture.publish(draft) }

        let published = try await fixture.publish(draft)
        let copies = fixture.server.gists.filter { $0.files[draft.filename]?.content == draft.text }
        #expect(copies.count == 1)
        let created = try #require(copies.first)
        #expect(published.gistID == created.id)
        #expect(published.state == .savedToGitHub)
        #expect(fixture.remote(created.id, draft.filename) == draft.text)
        #expect(fixture.count("POST /gists") == 1)
        let cached = try #require(await fixture.store.cachedLibrary(accountID: SyncFixture.account))
        #expect(cached.owned.map(\.id) == [created.id])
        #expect(cached.content(gist: created, filename: draft.filename) == draft.text)
    }

    @Test(arguments: [false, true])
    func publishComparesExactSourceBytes(edited: Bool) async throws {
        let composed = "caf\u{E9}", decomposed = "cafe\u{301}"
        #expect(composed == decomposed)
        let fixture = try SyncFixture()
        let gist = fixture.server.addGist(description: "Note", files: ["README.md": composed])
        var draft = try await fixture.open(gist)
        if edited { draft = try await fixture.type("mine", in: draft) }
        fixture.server.edit(gist.id, files: ["README.md": decomposed])

        let inspected = try await fixture.inspect(draft)
        if edited {
            guard case .conflict(let conflict) = inspected.state else {
                Issue.record("A byte-different remote is a change, got \(inspected.state)")
                return
            }
            #expect(conflict.remote?.utf8.elementsEqual(decomposed.utf8) == true)
            #expect(inspected.text == "mine")
        } else {
            #expect(inspected.text.utf8.elementsEqual(decomposed.utf8))
            #expect(inspected.generation == 1)
            let typed = try await fixture.type(composed, in: inspected)
            #expect(try await fixture.publish(typed).state == .savedToGitHub)
            #expect(fixture.remote(gist.id)?.utf8.elementsEqual(composed.utf8) == true)
            #expect(fixture.count("PATCH /gists/\(gist.id)") == 1)
        }
    }
}
