import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PhotoImageError: Error, Equatable, Sendable {
    case invalidImage
    case imageTooLarge
    case encodingFailed
}

public enum PhotoImage {
    private static let maximumByteCount = 50_000_000
    private static let maximumPixelCount = 100_000_000

    public static func pngData(from data: Data) throws -> Data {
        guard data.count <= maximumByteCount else { throw PhotoImageError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw PhotoImageError.invalidImage }
        guard width <= maximumPixelCount / height else { throw PhotoImageError.imageTooLarge }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PhotoImageError.invalidImage
        }
        return try encodePNG(image)
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else {
            throw PhotoImageError.encodingFailed
        }
        // Re-encoding the upright pixels avoids carrying Photos location/EXIF metadata into public storage.
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PhotoImageError.encodingFailed }
        guard result.length <= maximumByteCount else { throw PhotoImageError.imageTooLarge }
        return result as Data
    }
}
