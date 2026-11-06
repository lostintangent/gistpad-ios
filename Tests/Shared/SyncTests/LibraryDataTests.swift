import Foundation
import Testing
@testable import Sync

private func metadataOnly(_ gist: Gist) throws -> Gist {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(gist)
    let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    var object = try #require(parsed)
    let files = try #require(object["files"] as? [String: [String: Any]])
    object["files"] = files.mapValues { value in
        var file = value
        file.removeValue(forKey: "content")
        return file
    }
    return try decodeGist(JSONSerialization.data(withJSONObject: object))
}

@Suite struct LibraryDataTests {
    @Test func theLibraryCacheKeepsAccountScopedContentAndPreferencesOnDevice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let account = UUID()
        let full = try decodeGist(gistData(content: "A cached body\n- [ ] Task"))
        let metadata = try metadataOnly(full)
        let preferences = Preferences(metadata: [
            "tags": .object(["project": .object(["name": .string("Project Alpha"), "color": .string("gold")])]),
            "gistTags": .object(["abc123": .array([.string("project")])]),
            "pinnedGists": .array([.string("abc123")])
        ])
        let store = try DraftStore.open(url: url)
        try await store.cacheLibrary(owned: [metadata], starred: [], preferences: preferences, accountID: account)
        let before = try #require(try await store.cachedLibrary(accountID: account))
        #expect(before.content(gist: metadata, filename: "README.md") == nil)
        try await store.cacheGist(full, accountID: account)
        let reopened = try DraftStore.open(url: url)
        let cached = try #require(try await reopened.cachedLibrary(accountID: account))
        let gist = try #require(cached.owned.first)
        #expect(cached.content(gist: gist, filename: "README.md") == "A cached body\n- [ ] Task")
        #expect(cached.preferences == preferences)
        #expect(try await reopened.cachedLibrary(accountID: UUID()) == nil)
    }

    @Test func aNewGistUsesWebHeadingAndEmptyContentDefaults() {
        let one = Draft(accountID: UUID(), githubUserID: 42, description: "A title", content: nil)
        #expect(one.text == "# A title\n\n")
        #expect(one.filename == "README.md")
        #expect(one.gistID == nil)
        #expect(one.state == .savedLocally)
        #expect(Draft(accountID: UUID(), githubUserID: 42, description: "", content: nil).text == "")
    }

    @Test func shareLinksPercentEncodeEachFileComponentAndNeverPublishADraft() async throws {
        let filename = "Résumé #1? 100%.md"
        let gist = try decodeGist(gistData(filename: filename))
        let store = try DraftStore.open(inMemory: true)
        let account = UUID()
        let local = try await store.save(
            Draft(accountID: account, githubUserID: 42, gist: gist, filename: filename, text: "base"),
            text: "unpublished", generation: 1)
        let links = try GistLinks(gist: gist, filename: filename)
        #expect(links.shareURL.absoluteString == "https://gistpad.dev/#/share/abc123/R%C3%A9sum%C3%A9%20%231%3F%20100%25.md")
        #expect(links.githubURL.absoluteString == "https://gist.github.com/abc123")
        #expect(links.isSecret)
        #expect(try GistLinks(gist: gist).shareURL.absoluteString == "https://gistpad.dev/#/share/abc123")
        #expect(throws: GistLinks.Error.invalidFilename) {
            try GistLinks(gist: gist, filename: "not-published.md")
        }
        #expect(try await store.draft(id: local.id, accountID: account)?.state == .savedLocally)
    }
}
