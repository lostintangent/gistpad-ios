import CryptoKit
import Foundation

public enum ImageStorageError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidResponse
    case http(status: Int, retryAfter: Date?)
    case assetNotAvailable
    case assetMismatch
}

public actor ImageStorageClient {
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

    public nonisolated static func publicURL(gistID: String, assetID: UUID) throws -> URL {
        try objectURL(gistID: gistID, assetID: assetID, isPublic: true)
    }

    public func upload(
        _ data: Data, gistID: String, assetID: UUID, reconcileFirst: Bool = false
    ) async throws -> URL {
        let credential = try await token()
        if reconcileFirst, try await verifiedAsset(data, gistID: gistID, assetID: assetID) {
            return try Self.publicURL(gistID: gistID, assetID: assetID)
        }
        var request = URLRequest(url: try Self.objectURL(gistID: gistID, assetID: assetID, isPublic: false))
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(credential ?? publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.setValue("max-age=3600", forHTTPHeaderField: "Cache-Control")
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ImageStorageError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 409 {
                guard try await verifiedAsset(data, gistID: gistID, assetID: assetID) else {
                    throw ImageStorageError.assetNotAvailable
                }
                return try Self.publicURL(gistID: gistID, assetID: assetID)
            }
            throw ImageStorageError.http(
                status: response.statusCode, retryAfter: response.retryAfterDate
            )
        }
        guard try await verifiedAsset(data, gistID: gistID, assetID: assetID) else {
            throw ImageStorageError.assetNotAvailable
        }
        return try Self.publicURL(gistID: gistID, assetID: assetID)
    }

    private func verifiedAsset(_ expected: Data, gistID: String, assetID: UUID) async throws -> Bool {
        var request = URLRequest(
            url: try Self.publicURL(gistID: gistID, assetID: assetID),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ImageStorageError.invalidResponse }
        if response.statusCode == 404 { return false }
        guard response.statusCode == 200 else {
            throw ImageStorageError.http(status: response.statusCode, retryAfter: response.retryAfterDate)
        }
        guard data.count == expected.count, SHA256.hash(data: data) == SHA256.hash(data: expected) else {
            throw ImageStorageError.assetMismatch
        }
        return true
    }

    private nonisolated static func objectURL(gistID: String, assetID: UUID, isPublic: Bool) throws -> URL {
        guard !gistID.isEmpty, gistID.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }) else { throw ImageStorageError.invalidIdentifier }
        let prefix = isPublic ? "storage/v1/object/public" : "storage/v1/object"
        return AccountService.projectURL.appendingPathComponent(
            "\(prefix)/assets/\(gistID)/\(assetID.uuidString.lowercased()).png"
        )
    }

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
