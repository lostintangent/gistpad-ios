import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Uploads an image the way gistpad.dev does: one POST to `assets/<gist>/<uuid>.png`, then its public URL.
public struct ImageStorage: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case invalidImage
        case imageTooLarge
        case encodingFailed
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
        guard AccountStore.isPublishableKey(publishableKey) else { throw AccountError.invalidConfiguration }
        self.publishableKey = publishableKey
        self.session = session ?? GitHubClient.makeSession()
        self.token = token
    }

    public func upload(_ png: Data, gistID: String, assetID: UUID = UUID()) async throws -> URL {
        let path = "assets/\(gistID)/\(assetID.uuidString.lowercased()).png"
        let credential = try await token()
        var request = URLRequest(url: AccountStore.projectURL.appending(path: "storage/v1/object/\(path)"))
        request.httpMethod = "POST"
        request.httpBody = png
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(credential ?? publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.setValue("max-age=3600", forHTTPHeaderField: "Cache-Control")
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.http(status: status) }
        return AccountStore.projectURL.appending(path: "storage/v1/object/public/\(path)")
    }

    public static func markdown(_ url: URL) -> String { "![Image](\(url.absoluteString))" }
}

extension ImageStorage {
    private static let maximumByteCount = 50_000_000
    private static let maximumPixelCount = 100_000_000

    /// The image as an upright PNG without its location and EXIF metadata, ready to upload.
    public static func png(from data: Data) throws -> Data {
        guard data.count <= maximumByteCount else { throw Failure.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw Failure.invalidImage }
        guard width <= maximumPixelCount / height else { throw Failure.imageTooLarge }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.invalidImage
        }
        return try encodePNG(image)
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.encodingFailed
        }
        // Re-encoding the upright pixels avoids carrying location/EXIF metadata into public storage.
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        guard result.length <= maximumByteCount else { throw Failure.imageTooLarge }
        return result as Data
    }
}
