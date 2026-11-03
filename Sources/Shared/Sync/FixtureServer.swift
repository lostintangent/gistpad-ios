#if DEBUG
import Auth
import Foundation
import Comments
import Synchronization

/// GitHub and Supabase, answered from memory. Tests, previews and fixture launches hand `session` to the real
/// clients, so the cache, sync and publish paths run unchanged without a network or a real account.
public final class FixtureServer: Sendable {
    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var data: Data

        public init(status: Int = 200, headers: [String: String] = [:], data: Data = Data()) {
            self.status = status
            self.headers = headers
            self.data = data
        }
    }

    /// Answers a request before the fixture does, for failures and edge cases. Return nil to fall through.
    public typealias Intercept = @Sendable (URLRequest) async throws -> Response?

    public static let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let you = GitHubUser(id: 1, login: "octocat", avatarURL: nil)
    public static let someoneElse = GitHubUser(id: 2, login: "hubot", avatarURL: nil)

    public let session: URLSession
    public let credentials = Credentials()
    private let state: Mutex<State>

    fileprivate struct State {
        var gists: [Gist] = []
        var starred: Set<String> = []
        var comments: [String: [GistComment]] = [:]
        var metadata: [String: AnyJSON] = [
            "user_name": .string(FixtureServer.you.login), "sub": .string(String(FixtureServer.you.id))
        ]
        var requests: [String] = []
        var intercept: Intercept?
        var nextID = 1
    }

    public init(intercept: Intercept? = nil) {
        let id = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        configuration.httpAdditionalHeaders = [FixtureProtocol.header: id]
        session = URLSession(configuration: configuration)
        state = Mutex(State(intercept: intercept))
        FixtureProtocol.servers.withLock { $0[id] = self }
    }

    /// An account store that signs in to this server and keeps its credentials in memory.
    public func accounts() throws -> AccountStore {
        try AccountStore(
            publishableKey: "sb_publishable_fixture", credentials: credentials, session: session,
            automaticallyRefreshesToken: false,
            launchFlow: { _ in URL(string: "gistpad://auth-callback?code=fixture")! })
    }

    @discardableResult
    public func signIn(_ accounts: AccountStore) async throws -> Account {
        try await accounts.signIn()
    }

    /// The gists on GitHub right now, newest first.
    public var gists: [Gist] { state.withLock { $0.gists } }
    /// Every request so far, as "METHOD /path".
    public var requests: [String] { state.withLock { $0.requests } }

    public func intercept(_ intercept: Intercept?) {
        state.withLock { $0.intercept = intercept }
    }

    /// Merges `metadata` into the Supabase user's metadata, where the web keeps tags, pins and the rest.
    public func mergeMetadata(_ metadata: [String: AnyJSON]) {
        state.withLock { $0.metadata.merge(metadata) { $1 } }
    }

    @discardableResult
    public func addGist(
        id: String? = nil, description: String, files: [String: String], updatedAt: Date = .now,
        owner: GitHubUser = FixtureServer.you, isStarred: Bool = false, comments: [String] = []
    ) -> Gist {
        state.withLock { state in
            let id = id ?? state.newID()
            let gist = Gist(
                id: id, description: description,
                files: files.reduce(into: [:]) { $0[$1.key] = .fixture($1.key, content: $1.value) },
                updatedAt: updatedAt.wholeSeconds, createdAt: updatedAt.wholeSeconds, isPublic: false,
                owner: owner, truncated: false, history: [GistRevision(version: state.newID())],
                commentCount: comments.count)
            state.gists.insert(gist, at: 0)
            if isStarred { state.starred.insert(id) }
            state.comments[id] = comments.enumerated().map { index, body in
                GistComment(
                    id: Int64(index + 1), body: body, user: .init(id: owner.id, login: owner.login),
                    createdAt: gist.updatedAt, updatedAt: gist.updatedAt)
            }
            return gist
        }
    }

    /// Changes a gist the way the web would, without counting as one of the app's requests. A nil file deletes it.
    public func edit(_ id: String, description: String? = nil, files: [String: String?] = [:]) {
        state.withLock { state in
            _ = state.update(id, with: .init(
                description: description,
                files: files.mapValues { $0.map { .init(content: $0, filename: nil) } }, public: nil))
        }
    }

    public static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
            data.append(buffer, count: count)
        }
        return data
    }

    fileprivate func respond(to request: URLRequest) async throws -> Response {
        if let intercept = state.withLock({ $0.intercept }), let response = try await intercept(request) {
            return response
        }
        guard let url = request.url else { throw URLError(.badURL) }
        let method = request.httpMethod ?? "GET"
        let body = Self.body(of: request)
        return try state.withLock { state in
            state.requests.append("\(method) \(url.path)")
            switch url.host {
            case "api.github.com": return try state.github(method, Array(url.pathComponents.dropFirst()), body)
            case "gist.githubusercontent.com": return state.raw(Array(url.pathComponents.dropFirst()))
            default: return try state.supabase(method, url.path, body)
            }
        }
    }
}

extension FixtureServer {
    /// Keychain-free credentials, so fixtures never touch the real sign-in.
    public final class Credentials: AuthLocalStorage, Sendable {
        private let values = Mutex<[String: Data]>([:])
        public init() {}
        public func store(key: String, value: Data) throws { values.withLock { $0[key] = value } }
        public func retrieve(key: String) throws -> Data? { values.withLock { $0[key] } }
        public func remove(key: String) throws { _ = values.withLock { $0.removeValue(forKey: key) } }
    }
}

private extension FixtureServer.State {
    mutating func newID() -> String {
        defer { nextID += 1 }
        return String(format: "f%07x", nextID)
    }

    mutating func github(_ method: String, _ path: [String], _ body: Data) throws -> FixtureServer.Response {
        var route = path
        var id = "", comment = ""
        if route.count > 1, route[0] == "gists", route[1] != "starred" { id = route[1]; route[1] = ":id" }
        if route.count > 3 { comment = route[3]; route[3] = ":comment" }
        if !id.isEmpty, !gists.contains(where: { $0.id == id }) { return .init(status: 404) }
        switch "\(method) /\(route.joined(separator: "/"))" {
        case "GET /user":
            return try json(FixtureServer.you)
        case "GET /gists":
            return try json(gists.filter { $0.owner == FixtureServer.you }.map { served($0, listed: true) })
        case "GET /gists/starred":
            return try json(gists.filter { starred.contains($0.id) }.map { served($0, listed: true) })
        case "POST /gists":
            let create = try JSONDecoder().decode(Change.self, from: body)
            let files = (create.files ?? [:]).compactMapValues { $0?.content }
            guard !files.isEmpty, !files.values.contains("") else { return .init(status: 422) }
            gists.insert(Gist(
                id: newID(), description: create.description ?? "",
                files: files.reduce(into: [:]) { $0[$1.key] = .fixture($1.key, content: $1.value) },
                updatedAt: Date.now.wholeSeconds, createdAt: Date.now.wholeSeconds,
                isPublic: create.public ?? false, owner: FixtureServer.you, truncated: false,
                history: [GistRevision(version: newID())], commentCount: 0), at: 0)
            return try json(served(gists[0]), status: 201)
        case "GET /gists/:id":
            return try json(gists.first { $0.id == id }.map { served($0) })
        case "PATCH /gists/:id":
            return try json(update(id, with: JSONDecoder().decode(Change.self, from: body)).map { served($0) })
        case "DELETE /gists/:id":
            gists.removeAll { $0.id == id }
            return .init(status: 204)
        case "PUT /gists/:id/star":
            starred.insert(id)
            return .init(status: 204)
        case "DELETE /gists/:id/star":
            starred.remove(id)
            return .init(status: 204)
        case "GET /gists/:id/comments":
            return try json(comments[id, default: []])
        case "POST /gists/:id/comments":
            let posted = try JSONDecoder().decode([String: String].self, from: body)
            let created = GistComment(
                id: (comments[id, default: []].map(\.id).max() ?? 0) + 1, body: posted["body"] ?? "",
                user: .init(id: FixtureServer.you.id, login: FixtureServer.you.login),
                createdAt: Date.now.wholeSeconds, updatedAt: Date.now.wholeSeconds)
            comments[id, default: []].append(created)
            return try json(created, status: 201)
        case "DELETE /gists/:id/comments/:comment":
            comments[id]?.removeAll { String($0.id) == comment }
            return .init(status: 204)
        default:
            return .init(status: 404)
        }
    }

    /// The gist as GitHub serves it. Lists omit file contents.
    func served(_ gist: Gist, listed: Bool = false) -> Gist {
        Gist(
            id: gist.id, description: gist.description,
            files: gist.files.mapValues {
                GistFile(
                    filename: $0.filename, language: $0.language, content: listed ? nil : $0.content,
                    truncated: listed ? nil : $0.truncated,
                    rawURL: URL(string: "https://gist.githubusercontent.com")!
                        .appending(components: gist.owner?.login ?? "", gist.id, "raw", $0.filename),
                    size: $0.size)
            },
            updatedAt: gist.updatedAt, createdAt: gist.createdAt, isPublic: gist.isPublic, owner: gist.owner,
            truncated: gist.truncated, history: listed ? nil : gist.history,
            commentCount: comments[gist.id]?.count ?? 0)
    }

    /// A file's raw text, which lists link to instead of including.
    func raw(_ path: [String]) -> FixtureServer.Response {
        guard path.count == 4, let content = gists.first(where: { $0.id == path[1] })?.files[path[3]]?.content
        else { return .init(status: 404) }
        return .init(data: Data(content.utf8))
    }

    mutating func supabase(_ method: String, _ path: String, _ body: Data) throws -> FixtureServer.Response {
        switch (method, path) {
        case ("POST", "/auth/v1/token"):
            return try json([
                "access_token": "fixture-access", "refresh_token": "fixture-refresh", "token_type": "bearer",
                "expires_in": 3600, "expires_at": 4_102_444_800, "provider_token": "fixture-github",
                "user": user
            ] as [String: AnyJSON])
        case ("GET", "/auth/v1/user"):
            return try json(user)
        case ("PUT", "/auth/v1/user"):
            let update = try JSONDecoder().decode([String: AnyJSON].self, from: body)
            if case .object(let data)? = update["data"] { metadata.merge(data) { $1 } }
            return try json(user)
        case ("POST", "/auth/v1/logout"):
            return .init(status: 204)
        default:
            return .init(status: 404)
        }
    }

    var user: AnyJSON {
        [
            "id": .string(FixtureServer.accountID.uuidString), "aud": "authenticated",
            "created_at": "2026-10-23T20:00:00Z", "updated_at": "2026-10-23T20:00:00Z",
            "app_metadata": ["provider": "github"], "user_metadata": .object(metadata)
        ]
    }

    mutating func update(_ id: String, with change: Change) -> Gist? {
        guard let index = gists.firstIndex(where: { $0.id == id }) else { return nil }
        let gist = gists[index]
        var files = gist.files
        for (name, file) in change.files ?? [:] {
            let content = file?.content ?? files[name]?.content
            files[name] = nil
            guard file != nil, let content, !content.isEmpty else { continue }
            let filename = file?.filename ?? name
            files[filename] = .fixture(filename, content: content)
        }
        gists[index] = Gist(
            id: id, description: change.description ?? gist.description, files: files,
            updatedAt: Date.now.wholeSeconds, createdAt: gist.createdAt, isPublic: gist.isPublic,
            owner: gist.owner, truncated: false,
            history: [GistRevision(version: newID())] + (gist.history ?? []), commentCount: gist.commentCount)
        return gists[index]
    }

    func json<Value: Encodable>(_ value: Value?, status: Int = 200) throws -> FixtureServer.Response {
        guard let value else { return .init(status: 404) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return .init(status: status, headers: ["Content-Type": "application/json"], data: try encoder.encode(value))
    }

    struct Change: Decodable {
        struct File: Decodable {
            let content: String?
            let filename: String?
        }
        let description: String?
        let files: [String: File?]?
        let `public`: Bool?
    }
}

private extension GistFile {
    static func fixture(_ filename: String, content: String) -> GistFile {
        GistFile(
            filename: filename, language: filename.hasSuffix(".md") ? "Markdown" : nil, content: content,
            truncated: false, rawURL: nil, size: content.utf8.count)
    }
}

private extension Date {
    /// GitHub's timestamps have whole seconds.
    var wholeSeconds: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let header = "X-Fixture-Server"
    static let servers = Mutex<[String: FixtureServer]>([:])
    private let operation = Mutex<Task<Void, Never>?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let task = Task {
            do {
                let id = request.value(forHTTPHeaderField: Self.header) ?? ""
                guard let server = Self.servers.withLock({ $0[id] }), let url = request.url else {
                    throw URLError(.resourceUnavailable)
                }
                let result = try await server.respond(to: request)
                guard !Task.isCancelled else { return }
                let response = HTTPURLResponse(
                    url: url, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: result.headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: result.data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        operation.withLock { $0 = task }
    }

    override func stopLoading() { operation.withLock { $0?.cancel(); $0 = nil } }
}
#endif
