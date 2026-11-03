import Foundation
import Sync
import Testing
@testable import Platform

struct LibrarySnapshotTests {
    private let account = UUID()

    @Test func recentGistsAreYourOwnNewestEditFirstCountingUnpublishedEdits() async throws {
        let daily = try gist(
            "daily", DailyNote.gistDescription, updated: "2026-10-24T09:00:00Z",
            filename: DailyNote.filename())
        let archived = try gist("archived", "Old plans [Archived]", updated: "2026-10-24T08:00:00Z")
        let starred = try gist("starred", "Someone else's gist", updated: "2026-10-24T07:00:00Z")
        let edited = try gist("edited", "Edited on the phone", updated: "2026-10-19T00:00:00Z")
        let older = try gist("older", "Older", updated: "2026-10-18T00:00:00Z")
        let opened = try gist("opened", "Opened, not edited", updated: "2026-10-15T00:00:00Z")
        let store = try DraftStore.open(inMemory: true)
        // Opening a gist starts its draft, which mustn't make it recent.
        let openedDraft = try await store.draft(
            accountID: account, githubUserID: 42, gistID: opened.id, filename: "README.md",
            description: "Opened, not edited", content: "Text", revision: "1")
        let editing = try await store.draft(
            accountID: account, githubUserID: 42, gistID: edited.id, filename: "README.md",
            description: "Edited on the phone", content: "Text", revision: "1")
        let typed = try await store.persist(
            id: editing.id, accountID: account, text: "Typed on the phone", generation: 1)
        let started = try await store.newGistDraft(
            accountID: account, githubUserID: 42, description: "Started on the phone")
        let blank = try await store.newDraft(accountID: account, githubUserID: 42)
        let unpublishedDay = try await store.newDraft(
            accountID: account, githubUserID: 42, filename: DailyNote.filename(),
            description: DailyNote.gistDescription, text: "- [ ] Tomorrow")

        let snapshot = LibrarySnapshot.make(
            accountID: account,
            cache: CachedLibrary(
                accountID: account, owned: [daily, archived, edited, older, opened],
                starred: [starred],
                preferences: Preferences(metadata: [
                    "accentColor": .string("#0EA5E9"),
                    "tags": .object(["work": .object(["name": .string("Work")])]),
                    "gistTags": .object([edited.id: .array([.string("work")])])
                ])),
            drafts: [openedDraft, typed, started, blank, unpublishedDay])

        #expect(snapshot.recents.map(\.title) == ["Started on the phone", "Edited on the phone", "Older"])
        #expect(snapshot.recents.map(\.link) == [
            .unpublishedGist(accountID: account, draftID: started.id),
            .gist(id: edited.id, filename: nil), .gist(id: older.id, filename: nil)
        ])
        #expect(snapshot.recents[1].updatedAt == typed.updatedAt)
        #expect(snapshot.recents[1].tags == ["Work"])
        #expect(snapshot.gists.count == 9)
        #expect(snapshot.accentHex == "#0EA5E9")
    }

    private func gist(
        _ id: String, _ description: String, updated: String, filename: String = "README.md"
    ) throws -> Gist {
        let payload: [String: Any] = [
            "id": id, "description": description,
            "public": false, "owner": ["id": 42, "login": "synthetic"],
            "updated_at": updated, "created_at": "2026-10-01T00:00:00Z",
            "files": [filename: ["filename": filename, "language": "Markdown", "content": "Text"]],
            "history": [["version": "1"]]
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Gist.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}
