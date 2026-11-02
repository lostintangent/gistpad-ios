import Foundation
import Testing
@testable import GistPadSync

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
    @Test func cachePersistsAccountScopedContentAndSearchNeverNeedsTheNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.store")
        let account = UUID()
        let full = try decodeGist(gistData(content: "Hidden searchable body\n- [ ] Task"))
        let metadata = try metadataOnly(full)
        let preferences = Preferences(metadata: [
            "tags": .object(["project": .object(["name": .string("Project Alpha"), "color": .string("gold")])]),
            "gistTags": .object(["abc123": .array([.string("project")])]),
            "pinnedGists": .array([.string("abc123")])
        ])
        let store = try DraftStore.open(url: url)
        try await store.cacheLibrary(owned: [metadata], starred: [], preferences: preferences, accountID: account)
        let before = try #require(try await store.cachedLibrary(accountID: account))
        let missing = LibrarySearch.search(before, query: LibrarySearchQuery(text: "Hidden"))
        #expect(missing.matches.isEmpty)
        #expect(missing.documentsWithCachedContent == 0)
        try await store.cacheGist(full, accountID: account)
        let reopened = try DraftStore.open(url: url)
        let cached = try #require(try await reopened.cachedLibrary(accountID: account))
        let query = try LibrarySearchQuery(query: "hidden tag:\"Project Alpha\"", preferences: preferences)
        let result = LibrarySearch.search(cached, query: query)
        #expect(result.matches.count == 1)
        #expect(result.matches.first?.isPinned == true)
        #expect(result.matches.first?.progress?.remaining == 1)
        #expect(result.documentsWithCachedContent == result.totalDocuments)
        #expect(try await reopened.cachedLibrary(accountID: UUID()) == nil)
    }

    @Test func localDraftOverlaysSearchWithoutLeakingAcrossAccounts() async throws {
        let account = UUID()
        let gist = try decodeGist(gistData(content: "remote"))
        let library = CachedLibrarySnapshot(
            accountID: account, owned: [gist], starred: [], preferences: Preferences(metadata: [:])
        )
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: gist.id, filename: "README.md",
            description: "Note", content: "remote", revision: gist.revision
        )
        let local = try await store.persist(
            id: draft.id, accountID: account, text: "unpublished needle", generation: 1
        )
        let foreign = try await store.newDraft(
            accountID: UUID(), githubUserID: 99, text: "foreign needle"
        )
        let result = LibrarySearch.search(
            library, query: LibrarySearchQuery(text: "needle"), drafts: [local, foreign]
        )
        #expect(result.matches.count == 1)
        #expect(result.matches.first?.text == "unpublished needle")
    }

    @Test func tagTokensAreConjunctiveAndMalformedOrUnknownTokensAreExplicit() throws {
        let preferences = Preferences(metadata: [
            "tags": .object([
                "a": .object(["name": .string("Alpha")]),
                "b": .object(["name": .string("Beta Team")])
            ])
        ])
        let query = try LibrarySearchQuery(query: "#Alpha tag:\"Beta Team\" \"two words\"", preferences: preferences)
        #expect(query.tagIDs == ["a", "b"])
        #expect(query.terms == ["two words"])
        #expect(throws: LibrarySearchError.unknownTag("missing")) {
            try LibrarySearchQuery(query: "tag:missing", preferences: preferences)
        }
        #expect(throws: LibrarySearchError.unclosedQuote) {
            try LibrarySearchQuery(query: "\"unfinished", preferences: preferences)
        }
        #expect(throws: LibrarySearchError.invalidEscape) {
            try LibrarySearchQuery(query: "bad\\q", preferences: preferences)
        }
    }

    @Test func createDraftUsesWebHeadingAndEmptyContentDefaults() async throws {
        let store = try DraftStore.open(inMemory: true)
        let one = try await store.createGistDraft(accountID: UUID(), githubUserID: 42, description: "A title")
        #expect(one.text == "# A title\n\n")
        #expect(one.filename == "README.md")
        #expect(one.gistID == nil)
        #expect(one.state == .savedLocally)
        let empty = try await store.createGistDraft(accountID: UUID(), githubUserID: 42)
        #expect(empty.text == "")
    }

    @Test(arguments: ["template.md", "README.md", "2026.md", "2026-02-30.md"])
    func theDailyNotesSectionHoldsRealDaysIncludingUnpublishedOnes(filename: String) async throws {
        let account = UUID()
        let daily = try decodeGist(gistData(
            id: "daily", description: GistConventions.dailyNotesDescription, filename: filename))
        let dated = try decodeGist(gistData(
            id: "dated", content: "- [ ] A task",
            description: GistConventions.dailyNotesDescription, filename: "2024-02-29.md"))
        let ordinary = try decodeGist(gistData(id: "ordinary", filename: filename))
        let store = try DraftStore.open(inMemory: true)
        let invalid = try await store.newDraft(
            accountID: account, githubUserID: 42, filename: filename,
            description: GistConventions.dailyNotesDescription, text: "Not a day")
        let local = try await store.newDraft(
            accountID: account, githubUserID: 42, filename: "2026-10-24.md",
            description: GistConventions.dailyNotesDescription, text: "- [x] A task")
        let library = CachedLibrarySnapshot(
            accountID: account, owned: [daily, dated, ordinary], starred: [],
            preferences: Preferences(metadata: [:]))
        let all = LibrarySearch.search(library, collection: .all, drafts: [invalid, local])
        #expect(Set(all.matches.map(\.id)) == [
            "dated/2024-02-29.md", "ordinary/\(filename)", local.id.uuidString,
        ])
        #expect(all.totalDocuments == 3)
        #expect(all.documentsWithCachedContent == 3)
        let days = LibrarySearch.search(library, collection: .dailyNotes, drafts: [invalid, local])
        #expect(Set(days.matches.map(\.id)) == ["dated/2024-02-29.md", local.id.uuidString])
        let unpublished = try #require(days.matches.first { $0.id == local.id.uuidString })
        #expect(unpublished.draftID == local.id)
        #expect(unpublished.isDailyNote)
        #expect(unpublished.title == "2026-10-24")
        #expect(unpublished.progress?.remaining == 0)
        #expect(LibrarySearch.search(library, collection: .gists, drafts: [local]).matches.map(\.id)
            == ["ordinary/\(filename)"])
    }

    @Test func missingRemoteGistsRemainSearchableAsAccountScopedRecoveryDrafts() async throws {
        let account = UUID()
        let store = try DraftStore.open(inMemory: true)
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: "gone", filename: "Recovered.md",
            description: "Retained note", content: "saved text", revision: "one"
        )
        let local = try await store.persist(
            id: draft.id, accountID: account, text: "recoverable needle", generation: 1
        )
        let foreign = try await store.newDraft(accountID: UUID(), githubUserID: 99, text: "foreign needle")
        let library = CachedLibrarySnapshot(
            accountID: account, owned: [], starred: [], preferences: Preferences(metadata: [
                "tags": .object(["p": .object(["name": .string("Project")])]),
                "gistTags": .object(["gone": .array([.string("p")])])
            ])
        )
        let result = LibrarySearch.search(
            library, query: LibrarySearchQuery(text: "needle", tagIDs: ["p"]),
            drafts: [local, foreign]
        )
        #expect(result.matches.count == 1)
        #expect(result.matches.first?.draftID == draft.id)
        #expect(result.matches.first?.gistID == "gone")
        #expect(result.matches.first?.text == "recoverable needle")
        #expect(result.matches.first?.isRecovery == true)
        #expect(library.gists.isEmpty)
    }

    @Test func shareLinksPercentEncodeEachFileComponentAndNeverPublishADraft() async throws {
        let filename = "Résumé #1? 100%.md"
        let gist = try decodeGist(gistData(filename: filename))
        let store = try DraftStore.open(inMemory: true)
        let account = UUID()
        let draft = try await store.openDraft(
            accountID: account, githubUserID: 42, gistID: gist.id, filename: filename,
            description: "Note", content: "base", revision: gist.revision
        )
        let local = try await store.persist(
            id: draft.id, accountID: account, text: "unpublished", generation: 1
        )
        let links = try DocumentLinks(gist: gist, filename: filename)
        #expect(links.shareURL.absoluteString == "https://gistpad.dev/#/share/abc123/R%C3%A9sum%C3%A9%20%231%3F%20100%25.md")
        #expect(links.githubURL.absoluteString == "https://gist.github.com/abc123")
        #expect(links.isSecret)
        #expect(try DocumentLinks(gist: gist).shareURL.absoluteString == "https://gistpad.dev/#/share/abc123")
        #expect(throws: DocumentLinkError.invalidFilename) {
            try DocumentLinks(gist: gist, filename: "not-published.md")
        }
        #expect(try await store.draft(id: local.id, accountID: account).state == .savedLocally)
    }
}
