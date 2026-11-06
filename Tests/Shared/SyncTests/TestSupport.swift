import Foundation
import Testing
@testable import Sync

typealias FakeResponse = FixtureServer.Response

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

    /// A gist's file as you open it: your draft, or what GitHub has now.
    func open(_ gist: Gist, _ filename: String = "README.md") async throws -> Draft {
        let current = try #require(server.gists.first { $0.id == gist.id })
        let content = try #require(current.files[filename]?.content)
        return try await store.current(Draft(
            accountID: Self.account, githubUserID: Self.user, gist: current, filename: filename,
            text: GistFile.decodeContent(content)))
    }

    func type(_ text: String, in draft: Draft) async throws -> Draft {
        try await store.save(draft, text: text, generation: draft.generation + 1)
    }

    func publish(_ draft: Draft) async throws -> Draft {
        try await publisher.publish(draft)
    }
}

func temporaryStoreURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("drafts.store")
}
