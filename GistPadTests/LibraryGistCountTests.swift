import Foundation
import Testing
@testable import GistPadInterface
@testable import GistPad
@testable import GistPadSync

@MainActor
struct LibraryGistCountTests {
    @Test func countsUniqueGistsRatherThanFilesOrLocalRows() {
        let notes = [
            note("readme", gistID: "notebook"),
            note("ideas", gistID: "notebook"),
            note("today", gistID: "daily", isDailyNote: true),
            note("yesterday", gistID: "daily", isDailyNote: true),
            note("draft"),
            note("recovery"),
            note("friend", gistID: "shared", isOwned: false, isStarred: true)
        ]
        #expect(LibraryModel.gistCount(in: notes) == 3)
        #expect(LibraryModel.gistCount(in: []) == 0)
    }

    @Test func collectionTotalsIgnoreSearchAndTagFilters() {
        let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
        model.query = "no matching title"
        model.selectedTagIDs = ["design"]
        #expect(model.collectionGistCount == 4)
        #expect(model.resultGistCount == 0)
        model.collection = .starred
        #expect(model.collectionGistCount == 1)
        model.collection = .dailyNotes
        #expect(model.collectionGistCount == 1)
        model.collection = .archive
        #expect(model.collectionGistCount == 1)
    }

    @Test func homeGroupsCountOnlyTheirOwnGists() {
        let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
        model.snapshot.notes.append(note("local", isPinned: true))
        #expect(LibraryModel.gistCount(in: model.featuredNotes) == 1)
        #expect(LibraryModel.gistCount(in: model.listedNotes) == 3)
        #expect(model.collectionGistCount == 4)
        model.selectedTagIDs = ["design"]
        #expect(model.resultGistCount == 1)
        #expect(model.featuredNotes.isEmpty)
    }

    @Test func unknownAndConfirmedEmptyCountsStayDistinctThroughRefresh() {
        let model = LibraryModel()
        #expect(model.collectionGistCount == nil)
        model.snapshot.notes.append(note("unpublished"))
        model.query = "unpublished"
        #expect(model.resultGistCount == nil)
        model.replaceSnapshot(.init(notes: []))
        model.loadState = .ready
        #expect(model.collectionGistCount == 0)
        model.loadState = .loading
        #expect(model.collectionGistCount == 0)
        model.loadState = .offline
        #expect(model.collectionGistCount == 0)
        model.replaceSnapshot(InterfaceFixtures.library)
        model.loadState = .loading
        #expect(model.collectionGistCount == 4)
        model.replaceSnapshot(nil)
        #expect(model.collectionGistCount == nil)
        #expect(model.resultGistCount == nil)
    }

    @Test func resultsCountOnlyTheCompletedQueryAndDeduplicateItsFiles() {
        let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
        model.query = "a thought"
        model.searchState = .results(
            notes: [
                note("file-one", gistID: "one"),
                note("file-two", gistID: "one"),
                note("other-gist", gistID: "two"),
                note("recovery")
            ],
            coverage: .init(totalDocuments: 4, documentsWithCachedContent: 4))
        #expect(model.resultGistCount == 2)
        #expect(model.collectionGistCount == 4)
        model.searchState = .searching
        #expect(model.resultGistCount == nil)
        model.searchState = .failed(message: "A synthetic search failure")
        #expect(model.resultGistCount == nil)
        model.searchState = .results(
            notes: [], coverage: .init(totalDocuments: 0, documentsWithCachedContent: 0))
        #expect(model.resultGistCount == 0)
    }

    @Test func countLabelsUseGistUnitsAndCorrectSingular() {
        #expect(LibraryModel.gistCountLabel(0) == "0 gists")
        #expect(LibraryModel.gistCountLabel(1) == "1 gist")
        #expect(LibraryModel.gistCountLabel(12) == "12 gists")
    }

    @Test func productionLibraryProjectionSuppliesPublishedGistIdentity() {
        let account = NotebookAccount(
            id: UUID(), login: "synthetic-reader", preferences: .init(metadata: [:]))
        let owned = gist("owned")
        let daily = gist("daily", description: GistConventions.dailyNotesDescription)
        let shared = gist("shared")
        let snapshot = NotebookModel.librarySnapshot(
            owned: [owned, daily], starred: [owned, shared], account: account)
        #expect(Set(snapshot.notes.compactMap(\.gistID)) == ["owned", "daily", "shared"])
        #expect(snapshot.notes.allSatisfy { $0.fileCount == 2 })
        let model = LibraryModel(snapshot: snapshot, loadState: .ready)
        #expect(model.collectionGistCount == 1)
        model.collection = .dailyNotes
        #expect(model.collectionGistCount == 1)
        model.collection = .starred
        #expect(model.collectionGistCount == 2)
    }

    private func gist(_ id: String, description: String? = nil) -> Gist {
        let files = ["README.md", "Ideas.md"].map { filename in
            (filename, GistFile(
                filename: filename, language: "Markdown", content: nil, truncated: false,
                rawURL: nil, size: nil))
        }
        return .init(
            id: id, description: description, files: Dictionary(uniqueKeysWithValues: files),
            updatedAt: InterfaceFixtures.referenceDate, createdAt: InterfaceFixtures.referenceDate,
            isPublic: false, owner: nil, truncated: false, history: nil, commentCount: nil)
    }

    private func note(
        _ id: String, gistID: String? = nil, isOwned: Bool = true,
        isPinned: Bool = false, isDailyNote: Bool = false, isStarred: Bool = false
    ) -> LibraryNote {
        .init(
            id: id, title: id, updatedAt: InterfaceFixtures.referenceDate, gistID: gistID,
            isOwned: isOwned, isPinned: isPinned, isStarred: isStarred, isDailyNote: isDailyNote)
    }
}
