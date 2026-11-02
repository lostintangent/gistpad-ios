import Foundation
import GistPadSync
import Testing
@testable import GistPadPlatform

struct LibrarySnapshotTests {
    private let account = UUID()
    private let date = Date(timeIntervalSince1970: 1_792_800_000)
    private let zone = TimeZone(secondsFromGMT: 0)!

    @Test func theWidgetShowsTodaysTasksIncludingUnpublishedEdits() async throws {
        let filename = DailyNote.Day(date: date, timeZone: zone).filename
        let gist = try dailyGist(filename: filename, text: "- [ ] Cached")
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.draft(
            accountID: account, githubUserID: 42, gistID: gist.id, filename: filename,
            description: DailyNote.gistDescription, content: "- [ ] Cached", revision: "1")
        let source = "日本語 👩🏽‍💻\n- [ ] First\n  - [x] Second\n"
        let accepted = try await store.persist(
            id: draft.id, accountID: account, text: source, generation: 9)
        let snapshot = LibrarySnapshot.make(
            accountID: account, cache: cache(gist), drafts: [accepted], date: date, timeZone: zone)
        #expect(snapshot.today.tasks.map(\.title) == ["First", "Second"])
        #expect(snapshot.today.tasks.map(\.isChecked) == [false, true])
        #expect(snapshot.gists.map(\.link) == [.gist(id: gist.id, filename: nil)])
        #expect(snapshot.gists.first?.tags == ["Work"])
        #expect(snapshot.accentHex == "#0EA5E9")
    }

    private func cache(_ gist: Gist) -> CachedLibrary {
        CachedLibrary(
            accountID: account, owned: [gist], starred: [],
            preferences: Preferences(metadata: [
                "accentColor": .string("#0EA5E9"),
                "tags": .object(["work": .object(["name": .string("Work")])]),
                "gistTags": .object([gist.id: .array([.string("work")])])
            ]))
    }

    private func dailyGist(filename: String, text: String) throws -> Gist {
        let payload: [String: Any] = [
            "id": "daily123", "description": DailyNote.gistDescription,
            "public": false, "owner": ["id": 42, "login": "synthetic"],
            "updated_at": "2026-10-24T00:00:00Z", "created_at": "2026-10-24T00:00:00Z",
            "files": [filename: ["filename": filename, "language": "Markdown", "content": text]],
            "history": [["version": "1"]]
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Gist.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}
