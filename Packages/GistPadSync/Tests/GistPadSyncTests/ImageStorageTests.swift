import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import GistPadSync

func testPNG() throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.6, kCGImagePropertyGPSLongitude: -122.3],
        kCGImagePropertyOrientation: 6
    ] as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}

@Suite struct ImageStorageTests {
    @Test func requestAndMarkdownExactlyMatchWebStorageContract() async throws {
        let bytes = try testPNG()
        let asset = try #require(UUID(uuidString: "12345678-ABCD-4000-8000-123456789ABC"))
        let requests = Mutex<[String]>([])
        let storage = try ImageStorage(
            publishableKey: "sb_publishable_fake",
            session: FakeURLProtocol.session { request in
                requests.withLock { $0.append(request.httpMethod ?? "") }
                #expect(request.url?.host == "upnfachynwuwialgybvf.supabase.co")
                #expect(request.url?.path == "/storage/v1/object/assets/abc123/12345678-abcd-4000-8000-123456789abc.png")
                #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_fake")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-supabase-access")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/png")
                #expect(request.value(forHTTPHeaderField: "Cache-Control") == "max-age=3600")
                let body = try requestData(request)
                #expect(body == bytes)
                #expect(request.value(forHTTPHeaderField: "x-upsert") == nil)
                return FakeResponse(status: 200)
            }
        ) { "fake-supabase-access" }
        let url = try await storage.upload(bytes, gistID: "abc123", assetID: asset)
        #expect(url.absoluteString == "https://upnfachynwuwialgybvf.supabase.co/storage/v1/object/public/assets/abc123/12345678-abcd-4000-8000-123456789abc.png")
        #expect(requests.withLock { $0 } == ["POST"])
        #expect(ImageStorage.markdown(url) == "![Image](\(url.absoluteString))")
    }

    @Test func imageNormalizationProducesUprightPNGWithoutLocationMetadata() throws {
        let normalized = try ImageStorage.png(from: testPNG())
        let source = try #require(CGImageSourceCreateWithData(normalized as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 2)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(throws: ImageStorage.Failure.invalidImage) { try ImageStorage.png(from: Data("not an image".utf8)) }
    }
}
