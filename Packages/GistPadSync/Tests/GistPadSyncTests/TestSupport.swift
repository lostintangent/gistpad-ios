import Auth
import Foundation
import Synchronization
import Testing
@testable import GistPadSync

struct FakeResponse: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    var data: Data = Data()
}

final class FakeURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> FakeResponse
    static let handlers = Mutex<[String: Handler]>([:])
    private let operationTask = Mutex<Task<Void, Never>?>(nil)

    static func session(handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        handlers.withLock { $0[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-ID": id]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let operation = Task {
            do {
                let id = request.value(forHTTPHeaderField: "X-Test-ID") ?? ""
                guard let handler = Self.handlers.withLock({ $0[id] }) else {
                    throw URLError(.resourceUnavailable)
                }
                let result = try await handler(request)
                guard !Task.isCancelled else { return }
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: result.status,
                    httpVersion: "HTTP/1.1", headerFields: result.headers
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: result.data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        operationTask.withLock { $0 = operation }
    }

    override func stopLoading() { operationTask.withLock { $0?.cancel(); $0 = nil } }
}

final class MemoryCredentials: AuthLocalStorage, Sendable {
    private let values = Mutex<[String: Data]>([:])
    func store(key: String, value: Data) throws { values.withLock { $0[key] = value } }
    func retrieve(key: String) throws -> Data? { values.withLock { $0[key] } }
    func remove(key: String) throws { _ = values.withLock { $0.removeValue(forKey: key) } }
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
    let data: Data
    if let body = request.httpBody {
        data = body
    } else if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var result = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        data = result
    } else {
        throw URLError(.zeroByteResource)
    }
    return data
}
