import Auth
import Foundation
import Synchronization
import Testing
@testable import GistPadSync

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
