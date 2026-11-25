import Foundation
import Comments

public enum GitHubError: Error, Equatable, Sendable {
    case invalidResponse
    case http(status: Int)
    case incompleteGist
    case missingFile
    case fileTooLarge
}

extension GitHubError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .http(401): String(localized: "GitHub needs you to sign in again.")
        case .http(403), .http(429): String(localized: "GitHub declined the request.")
        case .http(404): String(localized: "This gist is no longer available to this account.")
        case .incompleteGist:
            String(localized: "GitHub returned an incomplete gist. It can’t be edited safely.")
        case .missingFile: String(localized: "This file is no longer in the gist.")
        case .fileTooLarge: String(localized: "This file is too large to open.")
        case .invalidResponse, .http: String(localized: "GitHub couldn’t complete the request.")
        }
    }
}

public actor GitHubClient {
    private let session: URLSession
    private let token: @Sendable () async throws -> String

    public init(session: URLSession, token: @escaping @Sendable () async throws -> String) {
        self.session = session
        self.token = token
    }

    /// The one real network session, shared by GitHub, Supabase and image uploads.
    public nonisolated static func makeSession() -> URLSession {
        #if DEBUG
            // Tests answer from a FixtureServer, so one that reaches for the real network stops here.
            precondition(
                NSClassFromString("XCTestCase") == nil,
                "Tests can't reach the real network. Pass a FixtureServer's session.")
        #endif
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func listGists() async throws -> [Gist] {
        try await list(path: "/gists?per_page=100", allowImages: true)
    }

    public func listStarredGists() async throws -> [Gist] {
        try await list(path: "/gists/starred?per_page=100", allowImages: false)
    }

    public func gist(id: String) async throws -> Gist {
        try await decoded(path: "/gists/\(try identifier(id))")
    }

    public func content(gist: Gist, filename: String) async throws -> String {
        guard gist.truncated != true else { throw GitHubError.incompleteGist }
        guard let file = gist.files[filename] else { throw GitHubError.missingFile }
        if file.truncated != true, let content = file.content { return content }
        guard let url = file.rawURL, url.scheme == "https",
              url.host == "gist.githubusercontent.com", url.user == nil, url.password == nil,
              url.port == nil else { throw GitHubError.invalidResponse }
        guard (file.size ?? 0) <= 10_000_000 else { throw GitHubError.fileTooLarge }
        // Raw URLs are unlisted, not credentials. Never forward the API token to this host.
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        guard response.statusCode == 200 else {
            throw GitHubError.http(status: response.statusCode)
        }
        guard data.count <= 10_000_000 else { throw GitHubError.fileTooLarge }
        guard let content = String(data: data, encoding: .utf8) else { throw GitHubError.invalidResponse }
        return Gist.File.decodeContent(content)
    }

    /// Fetches a gist and one file, enforcing ownership and completeness. `content` is nil when the file is gone.
    public func file(
        gistID: String, ownerID: Int64, filename: String
    ) async throws -> (gist: Gist, content: String?) {
        let gist = try await gist(id: gistID)
        guard gist.owner?.id == ownerID else { throw DraftError.readOnly }
        guard gist.truncated != true else { throw GitHubError.incompleteGist }
        guard gist.files[filename] != nil else { return (gist, nil) }
        return (gist, try await content(gist: gist, filename: filename))
    }

    /// Creates a secret gist, as the web does.
    public func createGist(description: String, filename: String, text: String) async throws -> Gist {
        struct Create: Encodable {
            let description: String
            let files: [String: FileChange]
            let `public` = false
        }
        return try await decoded(
            path: "/gists", method: "POST",
            body: JSONEncoder().encode(Create(description: description, files: [filename: .content(text)]))
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

    public func listComments(gistID: String) async throws -> [GistComment] {
        try await pages(path: "/gists/\(try identifier(gistID))/comments?per_page=100")
    }

    public func createComment(gistID: String, body: String) async throws -> GistComment {
        try await decoded(
            path: "/gists/\(try identifier(gistID))/comments", method: "POST",
            body: JSONEncoder().encode(["body": body]))
    }

    public func updateComment(
        gistID: String, commentID: Int64, body: String
    ) async throws -> GistComment {
        try await decoded(
            path: commentPath(gistID: gistID, commentID: commentID), method: "PATCH",
            body: JSONEncoder().encode(["body": body]))
    }

    public func deleteComment(gistID: String, commentID: Int64) async throws {
        _ = try await request(
            path: commentPath(gistID: gistID, commentID: commentID), method: "DELETE")
    }

    private func commentPath(gistID: String, commentID: Int64) throws -> String {
        guard commentID > 0 else { throw GitHubError.invalidResponse }
        return "/gists/\(try identifier(gistID))/comments/\(commentID)"
    }

    public func setStarred(_ starred: Bool, id: String) async throws {
        _ = try await request(
            path: "/gists/\(try identifier(id))/star", method: starred ? "PUT" : "DELETE"
        )
    }

    private func identifier(_ value: String) throws -> String {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { throw GitHubError.invalidResponse }
        return value
    }

    private func list(path: String, allowImages: Bool) async throws -> [Gist] {
        let gists: [Gist] = try await pages(path: path)
        var ids: Set<String> = []
        return gists.filter {
            $0.matchesWebMarkdownFilter(allowImages: allowImages) && ids.insert($0.id).inserted
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func pages<Element: Decodable>(path: String) async throws -> [Element] {
        var url: URL? = URL(string: "https://api.github.com\(path)")
        var visited: Set<URL> = []
        var result: [Element] = []
        while let current = url {
            guard visited.insert(current).inserted else { throw GitHubError.invalidResponse }
            let (data, link) = try await request(url: current)
            result += try decode([Element].self, from: data)
            url = try nextPage(link)
        }
        return result
    }

    private func nextPage(_ link: String?) throws -> URL? {
        guard let link else { return nil }
        for part in link.split(separator: ",") {
            guard part.contains(#"rel="next""#),
                  let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"),
                  start < end else { continue }
            guard let url = URL(string: String(part[part.index(after: start)..<end])) else {
                throw GitHubError.invalidResponse
            }
            try validate(url)
            return url
        }
        return nil
    }

    /// A body GitHub didn't mean is an invalid response, so Foundation's decoding wording never shows.
    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GitHubError.invalidResponse
        }
    }

    private func decoded<T: Decodable>(path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let (data, _) = try await request(path: path, method: method, body: body)
        return try decode(T.self, from: data)
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, String?) {
        guard let url = URL(string: "https://api.github.com\(path)") else { throw GitHubError.invalidResponse }
        return try await request(url: url, method: method, body: body)
    }

    private func validate(_ url: URL) throws {
        guard url.scheme == "https", url.host == "api.github.com", url.port == nil,
              url.user == nil, url.password == nil,
              url.path == "/gists" || url.path.hasPrefix("/gists/") else {
            throw GitHubError.invalidResponse
        }
    }

    private func request(url: URL, method: String = "GET", body: Data? = nil) async throws -> (Data, String?) {
        try validate(url)
        let accessToken = try await token()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        if method == "GET" { request.setValue("no-cache", forHTTPHeaderField: "Cache-Control") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubError.http(status: response.statusCode)
        }
        return (data, response.value(forHTTPHeaderField: "Link"))
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    // `@concurrent`, because Swift 6.4.2 crashes compiling this Objective-C async method as nonsending.
    @concurrent func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

extension GitHubClient {
    public enum FileChange: Encodable, Sendable {
        case content(String)
        case rename(String)
        case delete

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .content(let content): try container.encode(["content": Gist.File.encodeContent(content)])
            case .rename(let filename): try container.encode(["filename": filename])
            case .delete: try container.encodeNil()
            }
        }
    }
}
