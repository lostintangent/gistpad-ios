import Foundation
import GistPadSync
import Testing
@testable import GistPadPlatform

struct NotebookSystemTests {
    private let account = UUID()
    private let date = Date(timeIntervalSince1970: 1_792_800_000)
    private let zone = TimeZone(secondsFromGMT: 0)!

    @Test func acceptedDraftWinsOverCachedSourceAndExactTaskToggleIsDurable() async throws {
        let filename = DailyNoteTarget(date: date, timeZone: zone).filename
        let gist = try dailyGist(filename: filename, text: "- [ ] Cached")
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: gist.id, filename: filename,
            description: GistConventions.dailyNotesDescription, content: "- [ ] Cached", revision: "1")
        let source = "日本語 👩🏽‍💻\n- [ ] First  \r\n```md\n- [ ] Not a task\n```bad\n- [x] Still code\n```\n  - [x] Second\n- [X] Not the web marker\n"
        let accepted = try await store.persist(
            id: draft.id, accountID: account, text: source, generation: 9)
        let snapshot = NotebookSystemSnapshot.make(
            accountID: account, cache: cache(gist), drafts: [accepted], date: date, timeZone: zone)
        #expect(snapshot.today.tasks.map(\.title) == ["First", "Second"])
        #expect(snapshot.today.tasks.map(\.isCompleted) == [false, true])
        #expect(snapshot.notes.first?.tags == ["Work"])
        #expect(snapshot.accentHex == "#0EA5E9")
        let first = try #require(snapshot.today.tasks.first)
        let command = first.command(accountID: account, completed: true)
        #expect((source as NSString).substring(with: NSRange(location: command.edit.location, length: 1)) == " ")
        let updated = try await store.apply(command)
        #expect(updated.text == source.replacingOccurrences(of: "- [ ] First", with: "- [x] First"))
        #expect(updated.generation == 10)
        #expect(try await store.apply(command).generation == 10)
        await #expect(throws: DraftError.staleGeneration) {
            try await store.apply(first.command(accountID: account, completed: true))
        }
    }

    @Test func appendingTextAndMultilineTasksUsesTheExistingValidatedCommand() async throws {
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.newDraft(
            accountID: account, githubUserID: 42, text: "# Today\n\nA thought")
        let text = try TodayAppend.command(draft: draft, text: "A second thought", asTask: false)
        let appended = try await store.apply(text)
        #expect(appended.text == "# Today\n\nA thought\n\nA second thought\n")
        let tasks = try TodayAppend.command(
            draft: appended, text: "First task\n  \t\n日本語 👩🏽‍💻\n", asTask: true)
        let completed = try await store.apply(tasks)
        #expect(completed.text.hasSuffix("A second thought\n- [ ] First task\n- [ ] 日本語 👩🏽‍💻\n"))
        #expect(completed.generation == 2)
        #expect(throws: NotebookPlatformError.emptyText) {
            try TodayAppend.command(draft: completed, text: "\n  \t", asTask: true)
        }
        let stale = try TodayAppend.command(draft: draft, text: "Stale text", asTask: false)
        await #expect(throws: DraftError.staleGeneration) { try await store.apply(stale) }
    }

    @Test(arguments: ["\n", "\r\n", "\r", "\u{2028}"])
    func taskAnchorsPreserveEveryLineEnding(lineEnding: String) async throws {
        let store = try DraftStore.open(inMemory: true)
        let source = [
            "日本語 👩🏽‍💻", "- [ ] First", "```md", "- [ ] Not a task", "```", "  - [x] Second"
        ].joined(separator: lineEnding)
        let draft = try await store.newDraft(
            accountID: account, githubUserID: 42,
            filename: DailyNoteTarget(date: date, timeZone: zone).filename,
            description: GistConventions.dailyNotesDescription, text: source)
        let snapshot = NotebookSystemSnapshot.make(
            accountID: account, cache: nil, drafts: [draft], date: date, timeZone: zone)
        #expect(snapshot.today.tasks.map(\.title) == ["First", "Second"])
        let task = try #require(snapshot.today.tasks.last)
        let updated = try await store.apply(task.command(accountID: account, completed: false))
        #expect(updated.text == source.replacingOccurrences(of: "- [x] Second", with: "- [ ] Second"))
    }

    @Test @MainActor func acknowledgingAnOldRouteCannotDiscardANewerDestination() {
        let inbox = NotebookRouteInbox()
        inbox.submit(.today)
        let first = inbox.pending?.id
        inbox.submit(.note(gistID: "abc123", filename: "Exact.md", shared: true))
        if let first { inbox.acknowledge(first) }
        #expect(inbox.pending?.route == .note(gistID: "abc123", filename: "Exact.md", shared: true))
    }

    private func cache(_ gist: Gist) -> CachedLibrarySnapshot {
        CachedLibrarySnapshot(
            accountID: account, owned: [gist], starred: [],
            preferences: Preferences(metadata: [
                "accentColor": .string("#0EA5E9"),
                "tags": .object(["work": .object(["name": .string("Work")])]),
                "gistTags": .object([gist.id: .array([.string("work")])])
            ]))
    }

    private func dailyGist(filename: String, text: String) throws -> Gist {
        let payload: [String: Any] = [
            "id": "daily123", "description": GistConventions.dailyNotesDescription,
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
