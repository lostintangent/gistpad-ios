import Foundation
import Testing
@testable import Store

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
    try #require(JSONSerialization.jsonObject(with: FixtureServer.body(of: request)) as? [String: Any])
}

/// The fixture GitHub with a draft store, signed in as `FixtureServer.you`.
struct SyncFixture {
    static let account = FixtureServer.accountID
    static let user = FixtureServer.you.id
    let server: FixtureServer
    let store: GistFileDraftStore
    let github: GitHubClient

    init(store: GistFileDraftStore? = nil, server: FixtureServer = FixtureServer()) throws {
        self.server = server
        self.store = try store ?? GistFileDraftStore.open(inMemory: true)
        github = GitHubClient(session: server.session) { "fixture-github" }
    }

    /// A gist's file as you open it: your draft, or what GitHub has now.
    func open(_ gist: Gist, _ filename: String = "README.md") async throws -> GistFileDraft {
        let current = try await github.gist(id: gist.id)
        let unedited = GistFileDraft(
            accountID: Self.account, gist: current, filename: filename,
            text: try await github.content(gist: current, filename: filename))
        return try await store.current(unedited) ?? unedited
    }

    func type(_ text: String, in draft: GistFileDraft) async throws -> GistFileDraft {
        try await store.save(draft, text: text, github: draft.base)
    }
}

func temporaryStoreURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("drafts.store")
}
