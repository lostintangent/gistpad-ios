import Foundation
import Testing
@testable import Store

/// The gist as GitHub lists it, without its files' text or its history.
private func listed(_ gist: Gist) throws -> Gist {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(gist)
    let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    var object = try #require(parsed)
    object.removeValue(forKey: "history")
    let files = try #require(object["files"] as? [String: [String: Any]])
    object["files"] = files.mapValues { value in
        var file = value
        file.removeValue(forKey: "content")
        return file
    }
    return try decodeGist(JSONSerialization.data(withJSONObject: object))
}

@Suite struct LibraryDataTests {
    @Test func theGistCacheKeepsAccountScopedContentOnDevice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let account = UUID()
        let full = try decodeGist(gistData(content: "A cached body\n- [ ] Task"))
        let store = try GistFileDraftStore.open(url: url)
        var cache = GistCache(accountID: account)
        cache.replaceLists(owned: [try listed(full)], starred: [])
        #expect(cache.text(of: "README.md", in: try listed(full)) == nil)
        cache.update(full)
        try cache.save(to: store.modelContainer)

        let reopened = try GistFileDraftStore.open(url: url)
        var cached = try #require(try GistCache.load(accountID: account, from: reopened.modelContainer))
        // A refresh that lists the gist unchanged keeps its text current.
        cached.replaceLists(owned: [try listed(full)], starred: [])
        let gist = try #require(cached.owned.first)
        #expect(gist.files["README.md"]?.content == nil)
        #expect(cached.currentText(of: "README.md", in: gist) == "A cached body\n- [ ] Task")
        #expect(try GistCache.load(accountID: UUID(), from: reopened.modelContainer) == nil)
    }

    @Test func aNewGistUsesWebHeadingAndEmptyContentDefaults() {
        let one = GistFileDraft(accountID: UUID(), newGistName: "A title", content: nil)
        #expect(one.text == "# A title\n\n")
        #expect(one.filename == "README.md")
        #expect(one.gistID == nil)
        #expect(!one.isDisposable)
        #expect(GistFileDraft(accountID: UUID(), newGistName: "", content: nil).text == "")
    }

    @Test func shareLinksPercentEncodeEachFileComponentAndNeverPublishADraft() async throws {
        let filename = "Résumé #1? 100%.md"
        let gist = try decodeGist(gistData(filename: filename))
        let store = try GistFileDraftStore.open(inMemory: true)
        let account = UUID()
        let local = try await store.save(
            GistFileDraft(accountID: account, gist: gist, filename: filename, text: "base"),
            text: "unpublished", github: nil)
        let links = try GistLinks(gist: gist, filename: filename)
        #expect(links.shareURL.absoluteString == "https://gistpad.dev/#/share/abc123/R%C3%A9sum%C3%A9%20%231%3F%20100%25.md")
        #expect(links.githubURL.absoluteString == "https://gist.github.com/abc123")
        #expect(links.isSecret)
        #expect(try GistLinks(gist: gist).shareURL.absoluteString == "https://gistpad.dev/#/share/abc123")
        #expect(throws: GistLinks.Error.invalidFilename) {
            try GistLinks(gist: gist, filename: "not-published.md")
        }
        #expect(try await store.draft(id: local.id, accountID: account)?.isPublished == false)
    }
}
