import Foundation
import Editor
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

    @Test func eachMarkdownFileHasItsOwnNoteAndFrontMatterNeverReachesSiri() async throws {
        let source = "---\nprivate: a distracting instruction\n---\n\n# Ranked\nVagabond is first.\n"
        let manga = try gist(
            "manga", "Manga reading list", updated: "2026-10-24T09:00:00Z",
            files: ["README.md": source, "Calendars.md": "# Release dates\n"])
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.draft(
            accountID: account, githubUserID: 42, gistID: manga.id, filename: "README.md",
            description: manga.description ?? "", content: source, revision: "1")
        let edited = try await store.persist(
            id: draft.id, accountID: account, text: source + "Second favorite: Pluto.\n",
            generation: 1)
        let unpublishedFile = try await store.draft(
            accountID: account, githubUserID: 42, gistID: manga.id, filename: "Next.md",
            description: manga.description ?? "", content: "# Tomorrow\n", isNewFile: true)

        let snapshot = LibrarySnapshot.make(
            accountID: account,
            cache: CachedLibrary(
                accountID: account, owned: [manga], starred: [],
                preferences: Preferences(metadata: [:])),
            drafts: [edited, unpublishedFile],
            visibleText: { text in
                (text as NSString).substring(from: FrontMatter.contentStart(in: text))
            })

        #expect(snapshot.gists.count == 3)
        #expect(snapshot.recents.map(\.title) == ["Manga reading list"])
        let first = try #require(snapshot.gists.first {
            $0.link == GistPadLink.gist(id: manga.id, filename: nil)
        })
        let other = try #require(snapshot.gists.first {
            $0.link == GistPadLink.gist(id: manga.id, filename: "Calendars.md")
        })
        let newFile = try #require(snapshot.gists.first {
            $0.link == GistPadLink.gist(id: manga.id, filename: "Next.md")
        })
        #expect(first.body == nil)
        #expect(first.excerpt == "Vagabond is first. Second favorite: Pluto.")
        #expect(first.folderName == "Manga reading list")
        #expect(other.body == nil)
        #expect(newFile.body == nil)
        #expect(snapshot.gists.allSatisfy { $0.content == nil })
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!encoded.contains("\"body\""))
        #expect(!encoded.contains("a distracting instruction"))
        #expect(!encoded.contains("# Ranked"))
    }

    private func gist(
        _ id: String, _ description: String, updated: String, filename: String = "README.md",
        files: [String: String]? = nil
    ) throws -> Gist {
        let files = files ?? [filename: "Text"]
        let payload: [String: Any] = [
            "id": id, "description": description,
            "public": false, "owner": ["id": 42, "login": "synthetic"],
            "updated_at": updated, "created_at": "2026-10-01T00:00:00Z",
            "files": Dictionary(uniqueKeysWithValues: files.map { name, text in
                (name, ["filename": name, "language": "Markdown", "content": text])
            }),
            "history": [["version": "1"]]
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Gist.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}
