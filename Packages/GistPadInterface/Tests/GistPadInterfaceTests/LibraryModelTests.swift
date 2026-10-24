import Foundation
import Testing
@testable import GistPadInterface

@MainActor
struct LibraryModelTests {
    @Test func defaultCollectionExcludesDailyArchivedAndOtherOwners() {
        let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
        #expect(model.matchingNotes.map(\.id) == ["shape", "weekend", "words", "mixed"])
        #expect(model.pinnedNotes.map(\.id) == ["shape"])
        #expect(model.unpinnedNotes.map(\.id) == ["weekend", "words", "mixed"])
    }

    @Test func tagsUseANDAndTitleSearchIsLocalized() {
        let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
        model.selectedTagIDs = ["ideas", "design"]
        #expect(model.matchingNotes.map(\.id) == ["shape"])
        model.query = "  NOTEBOOK\n"
        #expect(model.matchingNotes.map(\.id) == ["shape"])
        model.query = "weekend"
        #expect(model.matchingNotes.isEmpty)
        model.clearFilters()
        #expect(!model.hasFilters)
        #expect(model.matchingNotes.count == 4)
    }

    @Test func collectionsPreserveOwnershipAndArchiveSemantics() {
        let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
        model.collection = .starred
        #expect(model.matchingNotes.map(\.id) == ["starred"])
        model.collection = .archive
        #expect(model.matchingNotes.map(\.id) == ["archived"])
        model.collection = .dailyNotes
        #expect(model.matchingNotes.map(\.id) == ["daily"])
    }

    @Test func selectedDocumentRemainsDiscoverableAfterFilterChangingEdit() {
        let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
        model.selectedNoteID = "shape"
        model.selectedTagIDs = ["design"]
        #expect(model.openDocumentOutsideFilter == nil)
        model.snapshot.notes[0].tagIDs = []
        #expect(model.matchingNotes.isEmpty)
        #expect(model.openDocumentOutsideFilter?.id == "shape")
        model.selectedNoteID = nil
        #expect(model.openDocumentOutsideFilter == nil)
    }

    @Test func equalTimestampsSortDeterministically() {
        let notes = ["c", "a", "b"].map {
            LibraryNote(id: $0, title: $0, updatedAt: InterfaceFixtures.referenceDate)
        }
        let model = LibraryModel(snapshot: .init(notes: notes))
        #expect(model.matchingNotes.map(\.id) == ["a", "b", "c"])
    }

    @Test func tagNamesDoNotDependOnSetOrder() {
        let model = LibraryModel(snapshot: InterfaceFixtures.library)
        #expect(model.tags(for: InterfaceFixtures.library.notes[0]).map(\.name) == ["Design", "Ideas"])
    }

    @Test func incompleteAndReadOnlyDocumentsCannotEdit() {
        #expect(NoteAccess.editable.canEdit)
        #expect(!NoteAccess.readOnly.canEdit)
        #expect(!NoteAccess.truncated.canEdit)
    }

    @Test func publishRequiresLocalWorkAndASafeRemoteState() {
        #expect(NoteSaveState.savedLocally.canPublish)
        #expect(NoteSaveState.unsaved.canPublish)
        #expect(NoteSaveState.cloudFailure(message: "Offline").canPublish)
        #expect(!NoteSaveState.inMemoryFixture.canPublish)
        #expect(!NoteSaveState.savedToGitHub.canPublish)
        #expect(!NoteSaveState.savingToGitHub.canPublish)
        #expect(!NoteSaveState.remoteChange.canPublish)
        #expect(!NoteSaveState.reconnectRequired.canPublish)
        #expect(!NoteSaveState.creationUncertain.canPublish)
        #expect(!NoteSaveState.publicationUncertain.canPublish)
        #expect(!NoteSaveState.publicationBlocked(message: "Incomplete").canPublish)
        #expect(!NoteSaveState.localFailure(message: "Disk full").canPublish)
    }
}
