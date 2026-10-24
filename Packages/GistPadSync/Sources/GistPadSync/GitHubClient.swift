import Foundation

public enum GitHubClientError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidResponse
    case unsafeURL
    case http(status: Int, retryAfter: Date?)
    case incompleteGist
    case missingFile
    case fileTooLarge
    case invalidUTF8
}

public actor GitHubClient {
    public typealias TokenProvider = @Sendable () async throws -> String
    private let session: URLSession
    private let token: TokenProvider
    private var cache: [URL: CachedResponse] = [:]
    private var cacheToken: String?
    private var cacheRevision = UUID()

    private struct CachedResponse {
        let data: Data
        let etag: String
        let link: String?
    }

    public init(session: URLSession? = nil, token: @escaping TokenProvider) {
        self.session = session ?? Self.makeSession()
        self.token = token
    }

    public nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func listGists() async throws -> [Gist] {
        try await list(path: "/gists?per_page=100", allowImages: true)
    }

    public func authenticatedUser() async throws -> GitHubUser {
        try await decoded(path: "/user")
    }

    public func listStarredGists() async throws -> [Gist] {
        try await list(path: "/gists/starred?per_page=100", allowImages: false)
    }

    public func gist(id: String) async throws -> Gist {
        try await decoded(path: "/gists/\(try identifier(id))")
    }

    public func content(gist: Gist, filename: String) async throws -> String {
        guard gist.truncated != true else { throw GitHubClientError.incompleteGist }
        guard let file = gist.files[filename] else { throw GitHubClientError.missingFile }
        if file.truncated != true, let content = file.content {
            return GistConventions.decodeContent(content)
        }
        guard let url = file.rawURL, url.scheme == "https",
              url.host == "gist.githubusercontent.com", url.user == nil, url.password == nil,
              url.port == nil else { throw GitHubClientError.unsafeURL }
        guard (file.size ?? 0) <= 10_000_000 else { throw GitHubClientError.fileTooLarge }
        // Raw URLs are unlisted, not credentials. Never forward the API token to this host.
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else { throw GitHubClientError.invalidResponse }
        guard response.statusCode == 200 else {
            throw GitHubClientError.http(status: response.statusCode, retryAfter: nil)
        }
        guard data.count <= 10_000_000 else { throw GitHubClientError.fileTooLarge }
        guard let content = String(data: data, encoding: .utf8) else { throw GitHubClientError.invalidUTF8 }
        return GistConventions.decodeContent(content)
    }

    public func createGist(
        description: String = "", filename: String = "README.md",
        content: String? = nil, isPublic: Bool = false
    ) async throws -> Gist {
        struct Create: Encodable {
            let description: String
            let files: [String: FileChange]
            let `public`: Bool
        }
        let initial = GistConventions.initialContent(description: description, content: content)
        return try await decoded(
            path: "/gists", method: "POST",
            body: JSONEncoder().encode(Create(
                description: description, files: [filename: .content(initial)], public: isPublic
            ))
        )
    }

    public func updateGist(
        id: String, description: String? = nil, files: [String: FileChange]? = nil
    ) async throws -> Gist {
        struct Update: Encodable {
            let description: String?
            let files: [String: FileChange]?
        }
        return try await decoded(
            path: "/gists/\(try identifier(id))", method: "PATCH",
            body: JSONEncoder().encode(Update(description: description, files: files))
        )
    }

    public func setArchived(_ archived: Bool, gist: Gist) async throws -> Gist {
        let description = archived
            ? "\(gist.displayName.trimmingCharacters(in: .whitespacesAndNewlines)) [Archived]"
            : gist.displayDescription
        return try await updateGist(id: gist.id, description: description)
    }

    public func updateDescription(_ description: String, gist: Gist) async throws -> Gist {
        try await updateGist(
            id: gist.id,
            description: gist.isArchived
                ? "\(description.trimmingCharacters(in: .whitespacesAndNewlines)) [Archived]"
                : description
        )
    }

    public func deleteGist(id: String) async throws {
        _ = try await request(path: "/gists/\(try identifier(id))", method: "DELETE")
    }

    public func setStarred(_ starred: Bool, id: String) async throws {
        _ = try await request(
            path: "/gists/\(try identifier(id))/star", method: starred ? "PUT" : "DELETE"
        )
    }

    public func clearCache() {
        cache.removeAll()
        cacheToken = nil
        cacheRevision = UUID()
    }

    private func identifier(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) }) else { throw GitHubClientError.invalidIdentifier }
        return value
    }

    private func list(path: String, allowImages: Bool) async throws -> [Gist] {
        var url: URL? = URL(string: "https://api.github.com\(path)")
        var visited: Set<URL> = []
        var result: [Gist] = []
        var ids: Set<String> = []
        while let current = url {
            guard visited.insert(current).inserted else { throw GitHubClientError.invalidResponse }
            let (data, link) = try await request(url: current)
            for gist in try decoder().decode([Gist].self, from: data)
                where gist.matchesWebMarkdownFilter(allowImages: allowImages) {
                if ids.insert(gist.id).inserted { result.append(gist) }
            }
            url = try nextPage(link)
        }
        return result.enumerated().sorted {
            if $0.element.updatedAt != $1.element.updatedAt { return $0.element.updatedAt > $1.element.updatedAt }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    private func nextPage(_ link: String?) throws -> URL? {
        guard let link else { return nil }
        for part in link.split(separator: ",") {
            guard part.contains(#"rel="next""#),
                  let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"),
                  start < end else { continue }
            guard let url = URL(string: String(part[part.index(after: start)..<end])) else {
                throw GitHubClientError.invalidResponse
            }
            try validate(url)
            return url
        }
        return nil
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func decoded<T: Decodable>(path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let (data, _) = try await request(path: path, method: method, body: body)
        return try decoder().decode(T.self, from: data)
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, String?) {
        guard let url = URL(string: "https://api.github.com\(path)") else { throw GitHubClientError.unsafeURL }
        return try await request(url: url, method: method, body: body)
    }

    private func validate(_ url: URL) throws {
        guard url.scheme == "https", url.host == "api.github.com", url.port == nil,
              url.user == nil, url.password == nil,
              url.path == "/user" || url.path == "/gists" || url.path.hasPrefix("/gists/") else {
            throw GitHubClientError.unsafeURL
        }
    }

    private func request(url: URL, method: String = "GET", body: Data? = nil) async throws -> (Data, String?) {
        try validate(url)
        let accessToken = try await token()
        if cacheToken != accessToken { clearCache(); cacheToken = accessToken }
        let revision = cacheRevision
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        if method == "GET" { request.setValue("no-cache", forHTTPHeaderField: "Cache-Control") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let cached = method == "GET" ? cache[url] : nil
        if let cached { request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GitHubClientError.invalidResponse }
        if response.statusCode == 304, let cached { return (cached.data, cached.link) }
        guard (200..<300).contains(response.statusCode) else {
            var retry = response.retryAfterDate
            if retry == nil, [403, 429].contains(response.statusCode) {
                if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                    retry = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
                        .flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
                } else {
                    retry = .now.addingTimeInterval(60)
                }
            }
            throw GitHubClientError.http(status: response.statusCode, retryAfter: retry)
        }
        let link = response.value(forHTTPHeaderField: "Link")
        if method == "GET", let etag = response.value(forHTTPHeaderField: "ETag"),
           cacheToken == accessToken, cacheRevision == revision {
            cache[url] = CachedResponse(data: data, etag: etag, link: link)
        } else if method != "GET" {
            clearCache()
        }
        return (data, link)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
