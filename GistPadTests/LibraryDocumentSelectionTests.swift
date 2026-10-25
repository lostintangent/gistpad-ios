import Testing

@testable import GistPadInterface

@Suite @MainActor
struct LibraryDocumentSelectionTests {
  @Test(arguments: [LibraryCollection.starred, .dailyNotes, .archive])
  func aCollectionDoesNotImportTheOpenDocumentFromAnotherScope(collection: LibraryCollection) {
    let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
    model.selectedNoteID = "shape"
    model.collection = collection
    #expect(model.visibleSelectedNoteID == nil)
    #expect(model.selectedNoteID == "shape")
    #expect(!model.matchingNotes.contains { $0.id == "shape" })
    #expect(!model.showsListedNotesHeading)
    model.collection = .gists
    #expect(model.visibleSelectedNoteID == "shape")
  }

  @Test func tagAndSearchChangesOnlyProjectVisibleSelectionFromTheRetainedDocument() {
    let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
    model.selectedNoteID = "shape"
    #expect(model.visibleSelectedNoteID == "shape")
    model.selectedTagIDs = ["missing"]
    #expect(model.visibleSelectedNoteID == nil)
    #expect(model.selectedNoteID == "shape")
    model.clearFilters()
    #expect(model.visibleSelectedNoteID == "shape")
    model.query = "No synthetic note matches"
    #expect(model.visibleSelectedNoteID == nil)
    #expect(model.selectedNoteID == "shape")
    model.searchState = .searching
    #expect(model.visibleSelectedNoteID == nil)
    model.searchState = .failed(message: "Synthetic search failure")
    #expect(model.visibleSelectedNoteID == nil)
    #expect(model.selectedNoteID == "shape")
    model.searchState = .inactive
    model.clearFilters()
    #expect(model.visibleSelectedNoteID == "shape")
    model.selectedNoteID = nil
    #expect(model.visibleSelectedNoteID == nil)
  }
}
