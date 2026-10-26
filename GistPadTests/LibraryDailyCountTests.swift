import Testing

@testable import GistPadInterface

@MainActor
struct LibraryDailyCountTests {
  @Test func dailyCountsNotesRatherThanTheirSharedGist() {
    var snapshot = InterfaceFixtures.library
    snapshot.dailyNoteCount = 2
    let model = LibraryModel(snapshot: snapshot, loadState: .ready)
    model.collection = .dailyNotes
    model.searchState = .results(
      notes: [],
      coverage: .init(totalDocuments: 2, documentsWithCachedContent: 2))
    #expect(model.dailyNoteCount == 2)
    #expect(model.collectionGistCount == 1)
  }

  @Test func dailyTotalSurvivesFilteringPendingSearchAndFailure() {
    var snapshot = InterfaceFixtures.library
    snapshot.dailyNoteCount = 2
    let model = LibraryModel(snapshot: snapshot, loadState: .ready)
    model.collection = .dailyNotes
    model.query = "no matching day"
    model.selectedTagIDs = ["ideas"]
    model.searchState = .results(
      notes: [],
      coverage: .init(totalDocuments: 1, documentsWithCachedContent: 1))
    #expect(model.dailyNoteCount == 2)
    #expect(model.resultGistCount == 0)
    model.searchState = .searching
    #expect(model.dailyNoteCount == 2)
    model.searchState = .failed(message: "A synthetic search failure")
    #expect(model.dailyNoteCount == 2)
  }

  @Test func unknownAndConfirmedEmptyDailyCountsRemainDistinct() {
    let model = LibraryModel()
    model.collection = .dailyNotes
    #expect(model.dailyNoteCount == nil)
    model.replaceSnapshot(.init(notes: [], dailyNoteCount: 0))
    #expect(model.dailyNoteCount == 0)
    model.loadState = .loading
    #expect(model.dailyNoteCount == 0)
    model.replaceSnapshot(InterfaceFixtures.library)
    #expect(model.dailyNoteCount == nil)
    var snapshot = InterfaceFixtures.library
    snapshot.dailyNoteCount = 2
    model.replaceSnapshot(snapshot)
    model.searchState = .results(
      notes: [],
      coverage: .init(totalDocuments: 2, documentsWithCachedContent: 2))
    #expect(model.dailyNoteCount == 2)
    model.replaceSnapshot(nil)
    #expect(model.dailyNoteCount == nil)
    model.replaceSnapshot(.init(notes: [], dailyNoteCount: 0))
    #expect(model.dailyNoteCount == 0)
  }

  @Test(arguments: [(0, "0 notes"), (1, "1 note"), (2, "2 notes")])
  func dailyLabelsUseNoteUnits(count: Int, expected: String) {
    #expect(LibraryModel.noteCountLabel(count) == expected)
  }
}
