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

private func imageDraft(store: DraftStore, account: UUID) async throws -> DraftSnapshot {
    try await store.openDraft(
        accountID: account, githubUserID: 42, gistID: "abc123", filename: "README.md",
        description: "Note", content: "Before after", revision: "one"
    )
}

@Suite struct ImageUploadTests {
    @Test func requestAndMarkdownExactlyMatchWebStorageContract() async throws {
        let bytes = try testPNG()
        let asset = try #require(UUID(uuidString: "12345678-ABCD-4000-8000-123456789ABC"))
        let requests = Mutex<[String]>([])
        let storage = try ImageStorageClient(
            publishableKey: "sb_publishable_fake",
            session: FakeURLProtocol.session { request in
                requests.withLock { $0.append(request.httpMethod ?? "") }
                #expect(request.url?.host == "upnfachynwuwialgybvf.supabase.co")
                if request.httpMethod == "POST" {
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
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                #expect(request.value(forHTTPHeaderField: "apikey") == nil)
                #expect(request.url?.path.contains("/object/public/assets/") == true)
                return FakeResponse(data: bytes)
            }
        ) { "fake-supabase-access" }
        let url = try await storage.upload(bytes, gistID: "abc123", assetID: asset)
        #expect(url.absoluteString == "https://upnfachynwuwialgybvf.supabase.co/storage/v1/object/public/assets/abc123/12345678-abcd-4000-8000-123456789abc.png")
        #expect(requests.withLock { $0 } == ["POST", "GET"])
    }

    @Test func photoNormalizationProducesUprightPNGWithoutLocationMetadata() throws {
        let normalized = try PhotoImage.pngData(from: testPNG())
        let source = try #require(CGImageSourceCreateWithData(normalized as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 2)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let thumbnail = try PhotoImage.thumbnailData(from: normalized)
        let thumbnailSource = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let thumbnailProperties = try #require(
            CGImageSourceCopyPropertiesAtIndex(thumbnailSource, 0, nil) as? [CFString: Any]
        )
        #expect(thumbnailProperties[kCGImagePropertyGPSDictionary] == nil)
        #expect(try #require(thumbnailProperties[kCGImagePropertyPixelWidth] as? Int) <= 192)
        #expect(try #require(thumbnailProperties[kCGImagePropertyPixelHeight] as? Int) <= 192)
        #expect(throws: PhotoImageError.invalidImage) { try PhotoImage.pngData(from: Data("not an image".utf8)) }
    }

    @Test func offlineImageSurvivesRelaunchThenBecomesOneDurableInsertion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let account = UUID()
        let store = try DraftStore.open(url: url)
        let draft = try await imageDraft(store: store, account: account)
        let bytes = try testPNG()
        let queued = try await store.enqueueImage(
            pngData: bytes, draftID: draft.id, accountID: account, expectedGeneration: 0, insertionLocation: 7
        )
        let online = Mutex(false)
        let posts = Mutex(0)
        let storage = try ImageStorageClient(
            publishableKey: "sb_publishable_fake",
            session: FakeURLProtocol.session { request in
                guard online.withLock({ $0 }) else { throw URLError(.notConnectedToInternet) }
                if request.httpMethod == "POST" { posts.withLock { $0 += 1 }; return FakeResponse() }
                return FakeResponse(status: posts.withLock { $0 } > 0 ? 200 : 404, data: bytes)
            }
        ) { "fake-access" }
        let first = ImageUploadCoordinator(accountID: account, store: store, storage: storage)
        await #expect(throws: URLError.self) { try await first.upload(id: queued.id) }
        #expect(try await store.imageUpload(id: queued.id, accountID: account).publicURL == nil)
        #expect(try await store.draft(id: draft.id, accountID: account).text == "Before after")
        #expect(try await store.hasUnsyncedWork(accountID: account))
        let reopened = try DraftStore.open(url: url)
        #expect(try await reopened.imageData(id: queued.id, accountID: account) == bytes)
        online.withLock { $0 = true }
        let second = ImageUploadCoordinator(accountID: account, store: reopened, storage: storage)
        let attempts = try await second.resumePending()
        let uploaded = try #require(attempts.first).result.get()
        #expect(uploaded.state == .uploaded)
        let command = try await reopened.imageInsertion(id: queued.id, accountID: account)
        let inserted = try await reopened.applyImageInsertion(id: queued.id, accountID: account, command: command)
        #expect(inserted.text == "Before \(try #require(uploaded.insertionText))after")
        #expect(inserted.generation == 1)
        #expect(inserted.state == .savedLocally)
        let again = try DraftStore.open(url: url)
        #expect(try await again.applyImageInsertion(id: queued.id, accountID: account, command: command).generation == 1)
        #expect(try await again.imageUpload(id: queued.id, accountID: account).isInserted)
        #expect(posts.withLock { $0 } == 1)
    }

    @Test func timedOutUploadReconcilesTheSameAssetWithoutAnotherPost() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await imageDraft(store: store, account: account)
        let bytes = try testPNG()
        let queued = try await store.enqueueImage(
            pngData: bytes, draftID: draft.id, accountID: account, expectedGeneration: 0, insertionLocation: 0
        )
        let posts = Mutex(0)
        let storage = try ImageStorageClient(
            publishableKey: "sb_publishable_fake",
            session: FakeURLProtocol.session { request in
                if request.httpMethod == "POST" {
                    posts.withLock { $0 += 1 }
                    throw URLError(.timedOut)
                }
                return FakeResponse(data: bytes)
            }
        ) { "fake" }
        let first = ImageUploadCoordinator(accountID: account, store: store, storage: storage)
        await #expect(throws: URLError.self) { try await first.upload(id: queued.id) }
        let next = ImageUploadCoordinator(accountID: account, store: store, storage: storage)
        #expect(try await next.upload(id: queued.id).state == .uploaded)
        #expect(posts.withLock { $0 } == 1)
    }

    @Test func publicAssetMustExistAndMatchBeforeAnyLinkCanBeInserted() async throws {
        for mismatch in [false, true] {
            let account = UUID()
            let store = try DraftStore.open(inMemory: true)
            let draft = try await imageDraft(store: store, account: account)
            let queued = try await store.enqueueImage(
                pngData: testPNG(), draftID: draft.id, accountID: account, expectedGeneration: 0, insertionLocation: 0
            )
            let storage = try ImageStorageClient(
                publishableKey: "sb_publishable_fake",
                session: FakeURLProtocol.session { request in
                    if request.httpMethod == "POST" { return FakeResponse() }
                    return FakeResponse(status: mismatch ? 200 : 404, data: Data("wrong bytes".utf8))
                }
            ) { "fake" }
            let coordinator = ImageUploadCoordinator(accountID: account, store: store, storage: storage)
            await #expect(throws: mismatch ? ImageStorageError.assetMismatch : .assetNotAvailable) {
                try await coordinator.upload(id: queued.id)
            }
            let result = try await store.imageUpload(id: queued.id, accountID: account)
            #expect(result.publicURL == nil)
            #expect(result.state == (mismatch ? .failed(.assetMismatch) : .uncertain))
            await #expect(throws: ImageUploadError.notUploaded) {
                try await store.imageInsertion(id: queued.id, accountID: account)
            }
            #expect(try await store.draft(id: draft.id, accountID: account).text == draft.text)
        }
    }

    @Test func loadingAPhotoAcrossTypingPreservesBytesButNotAnUnsafeInsertionAnchor() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await imageDraft(store: store, account: account)
        _ = try await store.persist(id: draft.id, accountID: account, text: "new", generation: 1)
        let bytes = try testPNG()
        let queued = try await store.enqueueImage(
            pngData: bytes, draftID: draft.id, accountID: account,
            expectedGeneration: 0, insertionLocation: 12
        )
        #expect(queued.insertionGeneration == 0)
        #expect(queued.insertionLocation == 12)
        #expect(try await store.imageData(id: queued.id, accountID: account) == bytes)
        _ = try await store.setImageUploadState(.uploaded, id: queued.id, accountID: account)
        await #expect(throws: DraftError.staleGeneration) {
            try await store.imageInsertion(id: queued.id, accountID: account)
        }
        let fresh = try await store.imageInsertion(
            id: queued.id, accountID: account, expectedGeneration: 1, insertionLocation: 3
        )
        let changed = try await store.applyImageInsertion(id: queued.id, accountID: account, command: fresh)
        #expect(changed.text.hasPrefix("new![Image]("))
        await #expect(throws: DraftError.staleGeneration) {
            try await store.enqueueImage(
                pngData: bytes, draftID: draft.id, accountID: account,
                expectedGeneration: 3, insertionLocation: 0
            )
        }
    }

    @Test func interveningTypingRequiresAnExplicitCurrentInsertionPoint() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await imageDraft(store: store, account: account)
        let queued = try await store.enqueueImage(
            pngData: testPNG(), draftID: draft.id, accountID: account, expectedGeneration: 0, insertionLocation: 7,
            format: .html
        )
        _ = try await store.setImageUploadState(.uploaded, id: queued.id, accountID: account)
        _ = try await store.persist(id: draft.id, accountID: account, text: "new source", generation: 1)
        await #expect(throws: DraftError.staleGeneration) {
            try await store.imageInsertion(id: queued.id, accountID: account)
        }
        let command = try await store.imageInsertion(
            id: queued.id, accountID: account, expectedGeneration: 1, insertionLocation: 10
        )
        #expect(command.edit.replacement.hasPrefix("<img src=\"https://"))
        let changed = try await store.applyImageInsertion(id: queued.id, accountID: account, command: command)
        #expect(changed.text.hasPrefix("new source<img src="))
        #expect(changed.generation == 2)
        await #expect(throws: DraftError.accountMismatch) {
            try await store.imageUpload(id: queued.id, accountID: UUID())
        }
    }

    @Test func confirmedGistDeletionAlsoRemovesQueuedImageBytes() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.newDraft(accountID: account, githubUserID: 42, text: "")
        let bytes = try testPNG()
        let queued = try await store.enqueueImage(
            pngData: bytes, draftID: draft.id, accountID: account, expectedGeneration: 0, insertionLocation: 0
        )
        #expect(queued.state == .waitingForGist)
        let storage = try ImageStorageClient(
            publishableKey: "sb_publishable_fake",
            session: FakeURLProtocol.session { request in
                #expect(request.url?.path.contains("/abc123/") == true)
                return FakeResponse(data: request.httpMethod == "GET" ? bytes : Data())
            }
        ) { "fake" }
        let coordinator = ImageUploadCoordinator(accountID: account, store: store, storage: storage)
        await #expect(throws: ImageUploadError.unpublishedNote) { try await coordinator.upload(id: queued.id) }
        _ = try await store.acknowledge(
            id: draft.id, accountID: account, gistID: "abc123", content: "", revision: "one", generation: 0
        )
        let cleanup = try await store.removeDraftsForDeletedGist(gistID: "abc123", accountID: account)
        #expect(cleanup.removedDraftIDs == [draft.id])
        #expect(try await store.imageUploads(accountID: account).isEmpty)
        await #expect(throws: ImageUploadError.notFound) {
            try await coordinator.upload(id: queued.id)
        }
    }

    @Test func authenticationAndRateFailuresRemainExplicitAndDoNotMutateSource() async throws {
        for status in [401, 429] {
            let account = UUID()
            let store = try DraftStore.open(inMemory: true)
            let draft = try await imageDraft(store: store, account: account)
            let queued = try await store.enqueueImage(
                pngData: testPNG(), draftID: draft.id, accountID: account, expectedGeneration: 0, insertionLocation: 0
            )
            let requests = Mutex(0)
            let storage = try ImageStorageClient(
                publishableKey: "sb_publishable_fake",
                session: FakeURLProtocol.session { _ in
                    requests.withLock { $0 += 1 }
                    return FakeResponse(status: status, headers: ["Retry-After": "120"])
                }
            ) { "fake" }
            let coordinator = ImageUploadCoordinator(accountID: account, store: store, storage: storage)
            await #expect(throws: ImageStorageError.self) { try await coordinator.upload(id: queued.id) }
            if status == 429 { #expect(try await coordinator.resumePending().isEmpty) }
            #expect(requests.withLock { $0 } == 1)
            let state = try await store.imageUpload(id: queued.id, accountID: account).state
            if status == 401 { #expect(state == .reconnect) }
            else {
                guard case .failed(.http(let code, let date)) = state else {
                    Issue.record("Missing rate-limit state")
                    continue
                }
                #expect(code == 429)
                #expect(try #require(date) > .now.addingTimeInterval(100))
                await #expect(throws: ImageUploadError.self) { try await coordinator.upload(id: queued.id) }
                #expect(requests.withLock { $0 } == 1)
            }
            #expect(try await store.draft(id: draft.id, accountID: account).text == draft.text)
        }
    }

    @Test func interruptedTransferReopensAsUncertainAndVerifiesBeforeAnyPost() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let account = UUID()
        let store = try DraftStore.open(url: url)
        let draft = try await imageDraft(store: store, account: account)
        let bytes = try testPNG()
        let queued = try await store.enqueueImage(
            pngData: bytes, draftID: draft.id, accountID: account, expectedGeneration: 0, insertionLocation: 0
        )
        _ = try await store.beginImageUpload(id: queued.id, accountID: account)
        let reopened = try DraftStore.open(url: url)
        #expect(try await reopened.imageUpload(id: queued.id, accountID: account).state == .uncertain)
        let storage = try ImageStorageClient(
            publishableKey: "sb_publishable_fake", session: FakeURLProtocol.session { request in
                #expect(request.httpMethod == "GET")
                return FakeResponse(data: bytes)
            }
        ) { "fake" }
        let coordinator = ImageUploadCoordinator(accountID: account, store: reopened, storage: storage)
        #expect(try await coordinator.upload(id: queued.id).state == .uploaded)
    }

    @Test func concurrentUploadRequestsShareOneTransferAndDiscardRemovesOnlyLocalQueueData() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await imageDraft(store: store, account: account)
        let bytes = try testPNG()
        let queued = try await store.enqueueImage(
            pngData: bytes, draftID: draft.id, accountID: account, expectedGeneration: 0, insertionLocation: 0
        )
        let posts = Mutex(0)
        let storage = try ImageStorageClient(
            publishableKey: "sb_publishable_fake", session: FakeURLProtocol.session { request in
                if request.httpMethod == "POST" { posts.withLock { $0 += 1 }; return FakeResponse() }
                return FakeResponse(data: bytes)
            }
        ) { "fake" }
        let coordinator = ImageUploadCoordinator(accountID: account, store: store, storage: storage)
        async let one = coordinator.upload(id: queued.id)
        async let two = coordinator.upload(id: queued.id)
        let values = try await [one, two]
        #expect(values[0] == values[1])
        #expect(posts.withLock { $0 } == 1)
        #expect(try await store.hasUnsyncedWork(accountID: account))
        try await store.discardImageUpload(id: queued.id, accountID: account)
        #expect(try await store.imageUploads(accountID: account).isEmpty)
        #expect(try await store.hasUnsyncedWork(accountID: account) == false)
        #expect(try await store.draft(id: draft.id, accountID: account).text == draft.text)
    }

    @Test func duplicateAssetResponseRequiresByteVerificationAndSupportsWebAnonymousFallback() async throws {
        let bytes = try testPNG()
        let storage = try ImageStorageClient(
            publishableKey: "sb_publishable_fake", session: FakeURLProtocol.session { request in
                if request.httpMethod == "POST" {
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sb_publishable_fake")
                    return FakeResponse(status: 409)
                }
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                return FakeResponse(data: bytes)
            }
        ) { nil }
        let id = UUID()
        #expect(try await storage.upload(bytes, gistID: "abc123", assetID: id)
            == ImageStorageClient.publicURL(gistID: "abc123", assetID: id))
    }

    @Test func duplicateWithDelayedPublicVisibilityStaysPendingAndCanResume() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await imageDraft(store: store, account: account)
        let bytes = try testPNG()
        let queued = try await store.enqueueImage(
            pngData: bytes, draftID: draft.id, accountID: account, expectedGeneration: 0, insertionLocation: 0
        )
        let visible = Mutex(false)
        let posts = Mutex(0)
        let storage = try ImageStorageClient(
            publishableKey: "sb_publishable_fake", session: FakeURLProtocol.session { request in
                if request.httpMethod == "POST" {
                    posts.withLock { $0 += 1 }
                    return FakeResponse(status: 409)
                }
                return FakeResponse(status: visible.withLock { $0 } ? 200 : 404, data: bytes)
            }
        ) { "fake" }
        let coordinator = ImageUploadCoordinator(accountID: account, store: store, storage: storage)
        await #expect(throws: ImageStorageError.assetNotAvailable) { try await coordinator.upload(id: queued.id) }
        #expect(try await store.imageUpload(id: queued.id, accountID: account).state == .uncertain)
        visible.withLock { $0 = true }
        let result = try await coordinator.resumePending()
        #expect(try #require(result.first).result.get().state == .uploaded)
        #expect(posts.withLock { $0 } == 1)
    }
}
