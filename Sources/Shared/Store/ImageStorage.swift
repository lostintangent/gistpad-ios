import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Uploads an image the way gistpad.dev does: one POST to `assets/<gist>/<uuid>.<extension>`, then its public URL.
public struct ImageStorage: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case invalidImage
        case imageTooLarge
        case http(status: Int)
    }

    public typealias TokenProvider = @Sendable () async throws -> String?
    private let publishableKey: String
    private let token: TokenProvider
    private let session: URLSession

    public init(
        publishableKey: String, session: URLSession? = nil,
        token: @escaping TokenProvider
    ) throws {
        guard GistPadAccountStore.isPublishableKey(publishableKey) else { throw AccountError.invalidConfiguration }
        self.publishableKey = publishableKey
        self.session = session ?? GitHubClient.makeSession()
        self.token = token
    }

    public func upload(_ image: Data, gistID: String, assetID: UUID = UUID()) async throws -> URL {
        let type = try Self.check(image)
        let fileExtension = type == .jpeg ? "jpg" : type.preferredFilenameExtension ?? ""
        let path = "assets/\(gistID)/\(assetID.uuidString.lowercased()).\(fileExtension)"
        let credential = try await token()
        var request = URLRequest(url: GistPadAccountStore.projectURL.appending(path: "storage/v1/object/\(path)"))
        request.httpMethod = "POST"
        request.httpBody = image
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(credential ?? publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue(type.preferredMIMEType, forHTTPHeaderField: "Content-Type")
        request.setValue("max-age=3600", forHTTPHeaderField: "Cache-Control")
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.http(status: status) }
        return GistPadAccountStore.projectURL.appending(path: "storage/v1/object/public/\(path)")
    }

    public static func markdown(_ url: URL) -> String { "![Image](\(url.absoluteString))" }
}

extension ImageStorage {
    private static let maximumByteCount = 50_000_000

    /// The type of an image storage takes as it is: under 50 MB, with a type its own bytes name.
    @discardableResult
    public static func check(_ image: Data) throws -> UTType {
        guard image.count <= maximumByteCount else { throw Failure.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
              type.preferredMIMEType != nil, type.preferredFilenameExtension != nil
        else { throw Failure.invalidImage }
        return type
    }
}
