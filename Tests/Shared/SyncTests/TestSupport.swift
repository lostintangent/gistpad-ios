import Auth
import Foundation
import Synchronization
import Testing
@testable import Sync

typealias FakeResponse = FixtureServer.Response
typealias MemoryCredentials = FixtureServer.Credentials

enum FakeURLProtocol {
    static func session(handler: @escaping @Sendable (URLRequest) async throws -> FakeResponse) -> URLSession {
        FixtureServer { try await handler($0) }.session
    }
}

func gistData(
    id: String = "abc123", content: String = "base", description: String = "Note",
    owner: Int64 = 42, revision: String = "revision1",
    filename: String = "README.md", language: String = "Markdown",
    truncated: Bool = false
) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "id": id, "description": description,
        "files": [filename: ["filename": filename, "language": language, "content": content]],
        "updated_at": "2026-10-23T20:00:00Z", "created_at": "2026-10-20T20:00:00Z",
        "public": false, "owner": ["id": owner, "login": "test-user"],
        "history": [["version": revision]], "truncated": truncated
    ])
}

func decodeGist(_ data: Data) throws -> Gist {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Gist.self, from: data)
}

func requestBody(_ request: URLRequest) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: requestData(request)) as? [String: Any])
}

func requestData(_ request: URLRequest) throws -> Data {
    FixtureServer.body(of: request)
}

/// The fixture GitHub with a draft store and publisher, signed in as `FixtureServer.you`.
struct SyncFixture {
    static let account = FixtureServer.accountID
    static let user = FixtureServer.you.id
    let server: FixtureServer
    let store: DraftStore
    let github: GitHubClient
    let publisher: DraftPublisher

    init(store: DraftStore? = nil, server: FixtureServer = FixtureServer()) throws {
        self.server = server
        self.store = try store ?? DraftStore.open(inMemory: true)
        github = GitHubClient(session: server.session) { "fixture-github" }
        publisher = DraftPublisher(client: github, store: self.store)
    }

    /// Your draft of a gist's file, opened from what GitHub has now.
    func open(_ gist: Gist, _ filename: String = "README.md") async throws -> Draft {
        let current = try #require(server.gists.first { $0.id == gist.id })
        return try await store.draft(
            accountID: Self.account, githubUserID: Self.user, gistID: gist.id, filename: filename,
            description: current.description ?? "", content: current.files[filename]?.content ?? "",
            revision: current.revision, isNewFile: current.files[filename] == nil)
    }

    func type(_ text: String, in draft: Draft) async throws -> Draft {
        try await store.persist(id: draft.id, accountID: Self.account, text: text, generation: draft.generation + 1)
    }

    func publish(_ draft: Draft) async throws -> Draft {
        try await publisher.publish(id: draft.id, accountID: Self.account)
    }

    func reload(_ draft: Draft) async throws -> Draft {
        try await store.draft(id: draft.id, accountID: Self.account)
    }

    /// The file's content on GitHub right now.
    func remote(_ gistID: String, _ filename: String = "README.md") -> String? {
        server.gists.first { $0.id == gistID }?.files[filename]?.content
    }

    func count(_ request: String) -> Int {
        server.requests.filter { $0 == request }.count
    }

    var dailyNotes: DailyNotes {
        DailyNotes(
            accountID: Self.account, githubUserID: Self.user, client: github, store: store, publisher: publisher)
    }
}

/// Lets a test hold a request at the fixture until it's released.
actor Gate {
    private var arrived = false
    private var open = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        arrived = true
        arrivals.forEach { $0.resume() }
        arrivals.removeAll()
        if !open { await withCheckedContinuation { held.append($0) } }
    }

    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { arrivals.append($0) } }
    }

    func release() {
        open = true
        held.forEach { $0.resume() }
        held.removeAll()
    }
}

func temporaryStoreURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("drafts.store")
}
