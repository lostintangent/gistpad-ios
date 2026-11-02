import Foundation

public enum ImageStorageError: Error, Equatable, Sendable {
    case http(status: Int)
}

/// Uploads a photo the way gistpad.dev does: one POST to `assets/<gist>/<uuid>.png`, then its public URL.
public struct ImageStorageClient: Sendable {
    public typealias TokenProvider = @Sendable () async throws -> String?
    private let publishableKey: String
    private let token: TokenProvider
    private let session: URLSession

    public init(
        publishableKey: String, session: URLSession? = nil,
        token: @escaping TokenProvider
    ) throws {
        guard AccountService.isPublishableKey(publishableKey) else { throw AccountError.invalidConfiguration }
        self.publishableKey = publishableKey
        self.session = session ?? GitHubClient.makeSession()
        self.token = token
    }

    public func upload(_ png: Data, gistID: String, assetID: UUID = UUID()) async throws -> URL {
        let path = "assets/\(gistID)/\(assetID.uuidString.lowercased()).png"
        let credential = try await token()
        var request = URLRequest(url: AccountService.projectURL.appending(path: "storage/v1/object/\(path)"))
        request.httpMethod = "POST"
        request.httpBody = png
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(credential ?? publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.setValue("max-age=3600", forHTTPHeaderField: "Cache-Control")
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ImageStorageError.http(status: status) }
        return AccountService.projectURL.appending(path: "storage/v1/object/public/\(path)")
    }

    public static func markdown(_ url: URL) -> String { "![Image](\(url.absoluteString))" }
}

extension HTTPURLResponse {
    var retryAfterDate: Date? {
        guard let value = value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) { return .now.addingTimeInterval(max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
