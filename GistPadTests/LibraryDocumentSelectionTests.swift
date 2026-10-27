import Testing

@testable import GistPadInterface

@Suite @MainActor
struct LibraryDocumentSelectionTests {
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
