import Foundation
import Synchronization
import Testing
@testable import GistPadSync

private func dailyData(
    id: String = "abc123", files: [String: String] = [:], truncated: Bool = false
) throws -> Data {
    let parsed = try JSONSerialization.jsonObject(with: gistData(
        id: id, description: GistConventions.dailyNotesDescription
    )) as? [String: Any]
    var object = try #require(parsed)
    var named: [String: Any] = [:]
    for (filename, content) in files {
        named[filename] = ["filename": filename, "language": "Markdown", "content": content]
    }
    object["files"] = named
    object["truncated"] = truncated
    return try JSONSerialization.data(withJSONObject: object)
}

private func arrayData(_ data: [Data]) -> Data {
    Data("[".utf8) + data.enumerated().reduce(into: Data()) { result, item in
        if item.offset > 0 { result += Data(",".utf8) }
        result += item.element
    } + Data("]".utf8)
}

@Suite struct DailyNotesTests: Sendable {
    private let target = DailyNoteTarget(
        date: Date(timeIntervalSince1970: 1_792_800_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )

    @Test func openingExistingTodayIsReadOnlyAndRetainsDirtyLocalWork() async throws {
        let target = DailyNoteTarget(
            date: try Date.ISO8601FormatStyle().parse("2026-10-24T12:00:00Z"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let existing = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "abc123", filename: target.filename,
            description: GistConventions.dailyNotesDescription, content: "remote", revision: "one"
        )
        _ = try await store.persist(id: existing.id, accountID: account, text: "local", generation: 1)
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            #expect(request.httpMethod == "GET")
            let gist = try dailyData(files: [target.filename: "remote"])
            return FakeResponse(data: request.url?.path == "/gists" ? arrayData([gist]) : gist)
        }) { "fake" }
        let service = DailyNotesService(
            accountID: account, githubUserID: 42, client: client, store: store,
            coordinator: SyncCoordinator(client: client, store: store)
        )
        let result = try await service.openToday(target: target)
        #expect(result.draft.id == existing.id)
        #expect(result.draft.text == "local")
        #expect(result.draft.state == .savedLocally)
    }

    @Test func cachedTodayStartIsLocalAndRetainsTheSameTypedDraft() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let gist = try decodeGist(dailyData(files: ["template.md": "# {{date}}\n\n- [ ] Plan"]))
        try await store.cacheLibrary(
            owned: [gist], starred: [], preferences: .init(metadata: [:]), accountID: account)
        let client = GitHubClient(session: FakeURLProtocol.session { _ in
            Issue.record("A cached Today start must not access GitHub")
            throw URLError(.notConnectedToInternet)
        }) { "fake" }
        let service = DailyNotesService(
            accountID: account, githubUserID: 42, client: client, store: store,
            coordinator: SyncCoordinator(client: client, store: store))
        let first = try await service.stageToday(target: target)
        #expect(first.draft.gistID == gist.id)
        #expect(first.draft.text == "# \(target.filename.dropLast(3))\n\n- [ ] Plan")
        #expect(first.draft.state == .savedLocally)
        #expect(first.draft.attemptedGeneration == nil)
        _ = try await store.persist(
            id: first.draft.id, accountID: account, text: "Already writing", generation: 1)
        let next = try await service.stageToday(target: target)
        #expect(next.draft.id == first.draft.id)
        #expect(next.draft.text == "Already writing")
        #expect(next.draft.generation == 1)
        #expect(try await store.drafts(accountID: account).count == 1)
    }

    @Test func cachedExistingTodayOpensWithoutFetchingOrPublishing() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let gist = try decodeGist(dailyData(files: [target.filename: "Cached Today"]))
        try await store.cacheLibrary(
            owned: [gist], starred: [], preferences: .init(metadata: [:]), accountID: account)
        let client = GitHubClient(session: FakeURLProtocol.session { _ in
            Issue.record("Current cached Today content must open without HTTP")
            throw URLError(.notConnectedToInternet)
        }) { "fake" }
        let service = DailyNotesService(
            accountID: account, githubUserID: 42, client: client, store: store,
            coordinator: SyncCoordinator(client: client, store: store))
        let result = try await service.stageToday(target: target)
        #expect(result.draft.text == "Cached Today")
        #expect(result.draft.state == .savedToGitHub)
        #expect(result.draft.attemptedGeneration == nil)
    }

    @Test func unknownDailyIDUsesExistingReadFirstOpeningAndNeverPublishes() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let paths = Mutex<[String]>([])
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            #expect(request.httpMethod == "GET")
            paths.withLock { $0.append(request.url?.path ?? "") }
            let gist = try dailyData(files: ["template.md": "- [ ] Discovered plan"])
            return FakeResponse(data: request.url?.path == "/gists" ? arrayData([gist]) : gist)
        }) { "fake" }
        let service = DailyNotesService(
            accountID: account, githubUserID: 42, client: client, store: store,
            coordinator: SyncCoordinator(client: client, store: store))
        let result = try await service.stageToday(target: target)
        #expect(paths.withLock { $0 } == ["/gists", "/gists/abc123"])
        #expect(result.draft.gistID == "abc123")
        #expect(result.draft.text == "- [ ] Discovered plan")
        #expect(result.draft.state == .savedLocally)
        #expect(result.draft.attemptedGeneration == nil)
        #expect(try await store.drafts(accountID: account).count == 1)
    }

    @Test func unavailableRequiredCachedTemplateNeverSilentlyUsesTheFallback() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        var object = try #require(
            try JSONSerialization.jsonObject(with: dailyData()) as? [String: Any])
        object["files"] = ["template.md": ["filename": "template.md", "language": "Markdown"]]
        let gist = try decodeGist(JSONSerialization.data(withJSONObject: object))
        try await store.cacheLibrary(
            owned: [gist], starred: [], preferences: .init(metadata: [:]), accountID: account)
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            #expect(request.httpMethod == "GET")
            throw URLError(.notConnectedToInternet)
        }) { "fake" }
        let service = DailyNotesService(
            accountID: account, githubUserID: 42, client: client, store: store,
            coordinator: SyncCoordinator(client: client, store: store))
        await #expect(throws: URLError.self) { try await service.stageToday(target: target) }
        #expect(try await store.drafts(accountID: account).isEmpty)
    }

    @Test func templateDayCreationIsTargetedAndConcurrentCallsDoNotDuplicateIt() async throws {
        let target = DailyNoteTarget(
            date: try Date.ISO8601FormatStyle().parse("2026-10-24T12:00:00Z"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let files = Mutex([
            "2026-10-23.md": "yesterday",
            "template.md": "# {{date}}\n\n- [ ] Plan {{date}}\n"
        ])
        let patches = Mutex(0)
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            #expect(request.httpMethod != "POST")
            if request.httpMethod == "PATCH" {
                let body = try requestBody(request)
                let changes = try #require(body["files"] as? [String: [String: String]])
                #expect(Set(changes.keys) == [target.filename])
                let text = try #require(changes[target.filename]?["content"])
                #expect(text == "# 2026-10-24\n\n- [ ] Plan 2026-10-24\n")
                files.withLock { $0[target.filename] = text }
                patches.withLock { $0 += 1 }
            }
            let data = try dailyData(files: files.withLock { $0 })
            return FakeResponse(data: request.url?.path == "/gists" ? arrayData([data]) : data)
        }) { "fake" }
        let store = try DraftStore.open(inMemory: true)
        let service = DailyNotesService(
            accountID: UUID(), githubUserID: 42, client: client, store: store,
            coordinator: SyncCoordinator(client: client, store: store)
        )
        async let one = service.openToday(target: target)
        async let two = service.openToday(target: target)
        let results = try await [one, two]
        #expect(results[0].draft.id == results[1].draft.id)
        #expect(results[0].draft.state == .savedToGitHub)
        #expect(results[0].gist?.files[target.filename] != nil)
        #expect(patches.withLock { $0 } == 1)
        _ = try await service.openToday(target: target)
        #expect(patches.withLock { $0 } == 1)
        #expect(files.withLock { $0["2026-10-23.md"] } == "yesterday")
    }

    @Test func noDailyGistCreatesOneSecretGistWithTheWebFallback() async throws {
        let target = DailyNoteTarget(
            date: try Date.ISO8601FormatStyle().parse("2026-10-24T12:00:00Z"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let created = Mutex(false)
        let creates = Mutex(0)
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            if request.httpMethod == "POST" {
                let body = try requestBody(request)
                #expect(body["description"] as? String == GistConventions.dailyNotesDescription)
                #expect(body["public"] as? Bool == false)
                let files = try #require(body["files"] as? [String: [String: String]])
                #expect(files[target.filename]?["content"] == "# 2026-10-24\n\n")
                creates.withLock { $0 += 1 }
                created.withLock { $0 = true }
            }
            let gist = try dailyData(files: [target.filename: "# 2026-10-24\n\n"])
            if request.url?.path == "/gists", request.httpMethod == "GET" {
                return FakeResponse(data: arrayData(created.withLock { $0 } ? [gist] : []))
            }
            return FakeResponse(data: gist)
        }) { "fake" }
        let store = try DraftStore.open(inMemory: true)
        let service = DailyNotesService(
            accountID: UUID(), githubUserID: 42, client: client, store: store,
            coordinator: SyncCoordinator(client: client, store: store)
        )
        let first = try await service.openToday(target: target)
        let next = try await service.openToday(target: target)
        #expect(first.draft.id == next.draft.id)
        #expect(next.draft.state == .savedToGitHub)
        #expect(creates.withLock { $0 } == 1)
    }

    @Test func timedOutFirstDailyGistCannotBeCreatedAgainAfterReopeningStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let account = UUID()
        let creates = Mutex(0)
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            if request.httpMethod == "POST" {
                creates.withLock { $0 += 1 }
                throw URLError(.timedOut)
            }
            return FakeResponse(data: Data("[]".utf8))
        }) { "fake" }
        for _ in 0..<2 {
            let store = try DraftStore.open(url: url)
            let service = DailyNotesService(
                accountID: account, githubUserID: 42, client: client, store: store,
                coordinator: SyncCoordinator(client: client, store: store)
            )
            await #expect(throws: (any Error).self) { try await service.openToday(target: target) }
        }
        #expect(creates.withLock { $0 } == 1)
    }

    @Test func duplicateDailyGistsFollowTheSameStableListOrderAsTheWeb() async throws {
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            #expect(request.httpMethod == "GET")
            if request.url?.path == "/gists" {
                return FakeResponse(data: try arrayData([
                    dailyData(id: "bbbb", files: [target.filename: "first"]),
                    dailyData(id: "aaaa", files: [target.filename: "second"])
                ]))
            }
            #expect(request.url?.lastPathComponent == "bbbb")
            return FakeResponse(data: try dailyData(id: "bbbb", files: [target.filename: "first"]))
        }) { "fake" }
        let store = try DraftStore.open(inMemory: true)
        let service = DailyNotesService(
            accountID: UUID(), githubUserID: 42, client: client, store: store,
            coordinator: SyncCoordinator(client: client, store: store)
        )
        #expect(try await service.openToday(target: target).draft.text == "first")
    }

    @Test func aTimedOutCreationIsReconciledAfterRelaunchWithoutLosingNewerTyping() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let account = UUID()
        let created = Mutex(false)
        let creates = Mutex(0)
        let text = GistConventions.dailyContent(template: nil, dateFilename: target.filename)
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            if request.httpMethod == "POST" {
                creates.withLock { $0 += 1 }
                created.withLock { $0 = true }
                throw URLError(.timedOut)
            }
            let gist = try dailyData(files: [target.filename: text])
            return FakeResponse(data: request.url?.path == "/gists"
                ? arrayData(created.withLock { $0 } ? [gist] : []) : gist)
        }) { "fake" }
        let store = try DraftStore.open(url: url)
        let first = DailyNotesService(
            accountID: account, githubUserID: 42, client: client, store: store,
            coordinator: SyncCoordinator(client: client, store: store)
        )
        await #expect(throws: URLError.self) { try await first.openToday(target: target) }
        let original = try #require(try await store.drafts(accountID: account).first)
        _ = try await store.persist(id: original.id, accountID: account, text: "new local task", generation: 1)
        let reopened = try DraftStore.open(url: url)
        let second = DailyNotesService(
            accountID: account, githubUserID: 42, client: client, store: reopened,
            coordinator: SyncCoordinator(client: client, store: reopened)
        )
        let result = try await second.openToday(target: target)
        #expect(result.draft.id == original.id)
        #expect(result.draft.gistID == "abc123")
        #expect(result.draft.text == "new local task")
        #expect(result.draft.baseContent == text)
        #expect(result.draft.state == .savedLocally)
        #expect(result.draft.attemptedGeneration == nil)
        #expect(try await reopened.drafts(accountID: account).count == 1)
        #expect(creates.withLock { $0 } == 1)
    }

    @Test func aPreviousDaysUncertainCreationCanBeReconciledWithoutCarryingItsTasksForward() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let original = try await store.dailyGistDraft(accountID: account, githubUserID: 42, target: target)
        try await store.beginAttempt(
            id: original.id, accountID: account, content: original.text, generation: 0
        )
        let next = DailyNoteTarget(
            date: try #require(DailyNotesIndex.parseDateFilename(
                target.filename, timeZone: TimeZone(secondsFromGMT: 0)!
            )).addingTimeInterval(86_400),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            #expect(request.httpMethod == "GET")
            let gist = try dailyData(files: [target.filename: original.text])
            return FakeResponse(data: request.url?.path == "/gists" ? arrayData([gist]) : gist)
        }) { "fake" }
        let service = DailyNotesService(
            accountID: account, githubUserID: 42, client: client, store: store,
            coordinator: SyncCoordinator(client: client, store: store)
        )
        let result = try await service.openToday(target: next, publishIfMissing: false)
        let recovered = try await store.draft(id: original.id, accountID: account)
        #expect(recovered.state == .savedToGitHub)
        #expect(recovered.gistID == "abc123")
        #expect(result.draft.filename == next.filename)
        #expect(result.draft.id != original.id)
        #expect(result.draft.text == GistConventions.dailyContent(template: nil, dateFilename: next.filename))
        #expect(result.draft.state == .savedLocally)
    }

    @Test func dayCreatedOnWebDuringTheFreshReadBecomesAConflictNotAnOverwrite() async throws {
        let details = Mutex(0)
        let client = GitHubClient(session: FakeURLProtocol.session { request in
            #expect(request.httpMethod == "GET")
            if request.url?.path == "/gists" {
                return FakeResponse(data: try arrayData([dailyData()]))
            }
            let count = details.withLock { $0 += 1; return $0 }
            return FakeResponse(data: try dailyData(
                files: count == 1 ? [:] : [target.filename: "web already wrote tasks"]
            ))
        }) { "fake" }
        let store = try DraftStore.open(inMemory: true)
        let service = DailyNotesService(
            accountID: UUID(), githubUserID: 42, client: client, store: store,
            coordinator: SyncCoordinator(client: client, store: store)
        )
        let result = try await service.openToday(target: target)
        guard case .conflict(let conflict) = result.draft.state else {
            Issue.record("Expected concurrent day creation to conflict")
            return
        }
        #expect(conflict.base == nil)
        #expect(conflict.remote == "web already wrote tasks")
    }

    @Test func todayAndItsTasksFollowTheWeb() throws {
        let instant = try Date.ISO8601FormatStyle().parse("2026-10-24T01:00:00Z")
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        #expect(DailyNoteTarget(date: instant, timeZone: la).filename == "2026-10-23.md")
        #expect(DailyNoteTarget(date: instant, timeZone: utc).filename == "2026-10-24.md")
        #expect(DailyNotesIndex.parseDateFilename("2026-02-30.md") == nil)

        let markdown = "🌅 - [ ] Wake up \r\n- [x] Done\n- [X] Shouting\n```\n- [ ] Fenced\n```"
        let tasks = FileTask.tasks(in: markdown)
        #expect(tasks.map(\.title) == ["Wake up", "Done", "Fenced"])
        #expect(tasks.map(\.isChecked) == [false, true, false])
        #expect(tasks[0].markerRange == NSRange(location: 5, length: 3))
        #expect((markdown as NSString).substring(with: tasks[0].lineRange) == "🌅 - [ ] Wake up ")
        #expect((markdown as NSString).substring(with: tasks[1].markerRange) == "[x]")
        #expect(TaskProgress(markdown: markdown) == TaskProgress(completed: 1, total: 3))

        let day = DailyNoteTarget(date: instant, timeZone: utc)
        let cache = { (truncated: Bool) in
            var object = try #require(try JSONSerialization.jsonObject(with: dailyData(
                files: [day.filename: "- [ ] Partial"])) as? [String: Any])
            object["files"] = [day.filename: [
                "filename": day.filename, "language": "Markdown", "content": "- [ ] Partial", "truncated": truncated]]
            return CachedLibrarySnapshot(
                accountID: UUID(), owned: [try decodeGist(JSONSerialization.data(withJSONObject: object))],
                starred: [], preferences: Preferences(metadata: [:]))
        }
        #expect(DailyNote(day: day, cache: try cache(true), drafts: []).progress == nil)
        let today = DailyNote(day: day, cache: try cache(false), drafts: [])
        #expect(today.gistID == "abc123")
        #expect(today.progress?.remaining == 1)
        #expect(today.date == DailyNotesIndex.parseDateFilename(day.filename, timeZone: utc))
        #expect(DailyNote(day: day, cache: nil, drafts: []).progress == nil)
        #expect(GistConventions.dailyContent(template: nil, dateFilename: "2026-10-24.md")
            == "# 2026-10-24\n\n")
        #expect(GistConventions.dailyContent(
            template: GistConventions.emptyContent, dateFilename: "2026-10-24.md"
        ) == "")
    }
}
