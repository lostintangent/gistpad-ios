import Foundation
import Comments

public enum GitHubClientError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidResponse
    case unsafeURL
    case http(status: Int)
    case incompleteGist
    case missingFile
    case fileTooLarge
    case invalidUTF8
}

extension GitHubClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .http(401): String(localized: "Reconnect GitHub to continue. Your gists on this iPhone are unchanged.")
        case .http(403), .http(429):
            String(localized: "GitHub declined the request. Try again later or reconnect GitHub.")
        case .http(404): String(localized: "This gist is no longer available to this account.")
        case .incompleteGist:
            String(localized: "GitHub returned an incomplete gist. It can't be edited safely.")
        case .missingFile: String(localized: "This file is no longer in the gist.")
        case .fileTooLarge: String(localized: "This file is too large to open.")
        case .invalidIdentifier, .invalidResponse, .unsafeURL, .invalidUTF8, .http:
            String(localized: "GitHub couldn't complete the request. Try again.")
        }
    }
}

public struct RemoteFile: Sendable {
    public let gist: Gist
    public let content: String?

    public init(gist: Gist, content: String?) {
        self.gist = gist
        self.content = content
    }
}

public actor GitHubClient {
    public typealias TokenProvider = @Sendable () async throws -> String
    private let session: URLSession
    private let token: TokenProvider

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
            return GistFile.decodeContent(content)
        }
        guard let url = file.rawURL, url.scheme == "https",
              url.host == "gist.githubusercontent.com", url.user == nil, url.password == nil,
              url.port == nil else { throw GitHubClientError.unsafeURL }
        guard (file.size ?? 0) <= 10_000_000 else { throw GitHubClientError.fileTooLarge }
        // Raw URLs are unlisted, not credentials. Never forward the API token to this host.
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else { throw GitHubClientError.invalidResponse }
        guard response.statusCode == 200 else {
            throw GitHubClientError.http(status: response.statusCode)
        }
        guard data.count <= 10_000_000 else { throw GitHubClientError.fileTooLarge }
        guard let content = String(data: data, encoding: .utf8) else { throw GitHubClientError.invalidUTF8 }
        return GistFile.decodeContent(content)
    }

    /// Fetches a gist and one file, enforcing ownership and completeness. `content` is nil when the file is gone.
    public func remoteFile(gistID: String, ownerID: Int64, filename: String) async throws -> RemoteFile {
        let gist = try await gist(id: gistID)
        guard gist.owner?.id == ownerID else { throw DraftError.readOnly }
        guard gist.truncated != true else { throw GitHubClientError.incompleteGist }
        guard gist.files[filename] != nil else { return RemoteFile(gist: gist, content: nil) }
        return RemoteFile(gist: gist, content: try await content(gist: gist, filename: filename))
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
        let initial = GistFile.initialContent(description: description, content: content)
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

    public func listComments(gistID: String) async throws -> [GistComment] {
        try await pages(path: "/gists/\(try identifier(gistID))/comments?per_page=100")
    }

    public func createComment(gistID: String, body: String) async throws -> GistComment {
        try await decoded(
            path: "/gists/\(try identifier(gistID))/comments", method: "POST",
            body: commentData(body))
    }

    public func updateComment(
        gistID: String, commentID: Int64, body: String
    ) async throws -> GistComment {
        try await decoded(
            path: commentPath(gistID: gistID, commentID: commentID), method: "PATCH",
            body: commentData(body))
    }

    public func deleteComment(gistID: String, commentID: Int64) async throws {
        _ = try await request(
            path: commentPath(gistID: gistID, commentID: commentID), method: "DELETE")
    }

    private func commentPath(gistID: String, commentID: Int64) throws -> String {
        guard commentID > 0 else { throw GitHubClientError.invalidIdentifier }
        return "/gists/\(try identifier(gistID))/comments/\(commentID)"
    }

    private func commentData(_ body: String) throws -> Data {
        struct CommentChange: Encodable { let body: String }
        return try JSONEncoder().encode(CommentChange(body: body))
    }

    public func setStarred(_ starred: Bool, id: String) async throws {
        _ = try await request(
            path: "/gists/\(try identifier(id))/star", method: starred ? "PUT" : "DELETE"
        )
    }

    private func identifier(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) }) else { throw GitHubClientError.invalidIdentifier }
        return value
    }

    private func list(path: String, allowImages: Bool) async throws -> [Gist] {
        let gists: [Gist] = try await pages(path: path)
        var ids: Set<String> = []
        return gists.filter {
            $0.matchesWebMarkdownFilter(allowImages: allowImages) && ids.insert($0.id).inserted
        }.enumerated().sorted {
            if $0.element.updatedAt != $1.element.updatedAt { return $0.element.updatedAt > $1.element.updatedAt }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    private func pages<Element: Decodable>(path: String) async throws -> [Element] {
        var url: URL? = URL(string: "https://api.github.com\(path)")
        var visited: Set<URL> = []
        var result: [Element] = []
        while let current = url {
            guard visited.insert(current).inserted else { throw GitHubClientError.invalidResponse }
            let (data, link) = try await request(url: current)
            result += try decoder().decode([Element].self, from: data)
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
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        if method == "GET" { request.setValue("no-cache", forHTTPHeaderField: "Cache-Control") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GitHubClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubClientError.http(status: response.statusCode)
        }
        return (data, response.value(forHTTPHeaderField: "Link"))
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

extension GitHubClient: CommentsRemote {}
