import Foundation
import Testing
@testable import GistPadInterface

@MainActor
struct LibraryModelTests {
    @Test func dailyCountBelongsToTheUnfilteredSnapshot() {
        let model = LibraryModel(snapshot: .init(notes: [], dailyNoteCount: 12), loadState: .ready)
        #expect(model.dailyNoteCount == 12)
        model.collection = .dailyNotes
        model.searchState = .results(
            notes: [], coverage: .init(
                totalDocuments: 3, documentsWithCachedContent: 3,
                incompleteGistCount: 0, staleResultCount: 0))
        #expect(model.dailyNoteCount == 12)
        model.replaceSnapshot(.init(notes: [], dailyNoteCount: 0))
        #expect(model.dailyNoteCount == 0)
        model.replaceSnapshot(.init(notes: []))
        #expect(model.dailyNoteCount == nil)
        model.replaceSnapshot(nil)
        #expect(model.dailyNoteCount == nil)
    }

    @Test(arguments: [nil, -1, 0, 1, 42] as [Int?])
    func commentMetadataOnlyExposesKnownPositiveGistTotals(count: Int?) {
        var note = LibraryNote(
            id: "gist", title: "A conversation", updatedAt: .now, gistID: "gist",
            commentCount: count)
        #expect(note.supportsComments)
        #expect(note.visibleCommentCount == count.flatMap { $0 > 0 ? $0 : nil })
        note.isDailyNote = true
        #expect(!note.supportsComments)
        #expect(note.visibleCommentCount == nil)
        note.isDailyNote = false
        note.gistID = nil
        #expect(!note.supportsComments)
        #expect(note.visibleCommentCount == nil)
    }

    @Test func defaultCollectionExcludesDailyArchivedAndOtherOwners() {
        let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
        #expect(model.matchingNotes.map(\.id) == ["shape", "weekend", "words", "mixed"])
        #expect(model.pinnedNotes.map(\.id) == ["shape"])
        #expect(model.unpinnedNotes.map(\.id) == ["weekend", "words", "mixed"])
    }

    @Test func featuredNotesAreDistinctFromTheDefaultScanList() {
        let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
        #expect(model.showsFeaturedNotes)
        #expect(model.featuredNotes.map(\.id) == ["shape"])
        #expect(model.listedNotes.map(\.id) == ["weekend", "words", "mixed"])
        let featuredIDs = Set(model.featuredNotes.map(\.id))
        #expect(model.listedNotes.allSatisfy { !featuredIDs.contains($0.id) })
    }

    @Test func filtersAndOtherCollectionsUseOneOrdinaryResultList() {
        let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
        model.selectedTagIDs = ["design"]
        #expect(!model.showsFeaturedNotes)
        #expect(model.featuredNotes.isEmpty)
        #expect(model.listedNotes.map(\.id) == ["shape"])
        model.clearFilters()
        model.collection = .starred
        #expect(!model.showsFeaturedNotes)
        #expect(model.listedNotes.map(\.id) == ["starred"])
    }

    @Test func defaultSearchDoesNotShowARedundantScopeCard() {
        let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
        model.query = "notebook"
        #expect(!model.showsSearchScope)
        model.selectedTagIDs = ["ideas"]
        #expect(model.showsSearchScope)
        model.selectedTagIDs = []
        model.collection = .starred
        #expect(model.showsSearchScope)
        model.query = ""
        #expect(!model.showsSearchScope)
    }

    @Test func appSearchNeverCreatesASecondFeaturedResultGroup() {
        let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
        let pinned = InterfaceFixtures.library.notes[0]
        model.searchState = .results(
            notes: [pinned], coverage: .init(totalDocuments: 1, documentsWithCachedContent: 1))
        #expect(model.featuredNotes.isEmpty)
        #expect(model.listedNotes == [pinned])
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

    @Test(arguments: LibraryCollection.allCases)
    func singleScopedListsDoNotRepeatTheirNavigationTitle(collection: LibraryCollection) {
        let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
        model.collection = collection
        #expect(model.showsListedNotesHeading == (collection == .gists))
    }

    @Test(arguments: [LibraryCollection.starred, .dailyNotes, .archive])
    func scopedHeadingsOnlyIdentifySearchResultsNotTheRetainedDocument(collection: LibraryCollection) {
        let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
        model.collection = collection
        model.selectedNoteID = "shape"
        #expect(model.visibleSelectedNoteID == nil)
        #expect(model.selectedNoteID == "shape")
        #expect(!model.showsListedNotesHeading)
        model.selectedNoteID = nil
        #expect(!model.showsListedNotesHeading)
        model.query = "note"
        #expect(model.showsListedNotesHeading)
    }

    @Test func selectedDocumentOutlivesItsVisibleSelectionAfterFilterChangingEdit() {
        let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
        model.selectedNoteID = "shape"
        model.selectedTagIDs = ["design"]
        #expect(model.visibleSelectedNoteID == "shape")
        model.snapshot.notes[0].tagIDs = []
        #expect(model.matchingNotes.isEmpty)
        #expect(model.visibleSelectedNoteID == nil)
        #expect(model.selectedNoteID == "shape")
        model.clearFilters()
        #expect(model.visibleSelectedNoteID == "shape")
        model.selectedNoteID = nil
        #expect(model.visibleSelectedNoteID == nil)
    }

    @Test func equalTimestampsSortDeterministically() {
        let notes = ["c", "a", "b"].map {
            LibraryNote(id: $0, title: $0, updatedAt: InterfaceFixtures.referenceDate)
        }
        let model = LibraryModel(snapshot: .init(notes: notes))
        #expect(model.matchingNotes.map(\.id) == ["a", "b", "c"])
    }

    @Test func appSearchResultsPreserveTargetsOrderAndFullTextMatches() {
        let model = LibraryModel(snapshot: InterfaceFixtures.library)
        model.query = "words that occur only in the body"
        model.selectedTagIDs = ["unknown-to-local-filter"]
        model.collection = .archive
        let notes = [
            LibraryNote(id: "new-draft", title: "A local note", updatedAt: .distantPast),
            LibraryNote(id: "daily/2026-10-23.md", title: "Today", updatedAt: .now, isDailyNote: true)
        ]
        model.searchState = .results(
            notes: notes,
            coverage: .init(totalDocuments: 5, documentsWithCachedContent: 2, staleResultCount: 1)
        )
        #expect(model.matchingNotes == notes)
        #expect(model.unpinnedNotes == notes)
    }

    @Test func searchFailuresAndPendingResultsNeverFallBackToTitleFiltering() {
        let model = LibraryModel(snapshot: InterfaceFixtures.library)
        model.searchState = .searching
        #expect(model.matchingNotes.isEmpty)
        model.searchState = .failed(message: "Unknown tag")
        #expect(model.matchingNotes.isEmpty)
        model.searchState = .inactive
        #expect(model.matchingNotes.count == 4)
    }

    @Test func cachedCoverageDoesNotPromiseCurrentContent() {
        #expect(LibrarySearchCoverage(totalDocuments: 0, documentsWithCachedContent: 0).isComplete)
        #expect(!LibrarySearchCoverage(totalDocuments: 4, documentsWithCachedContent: 3).isComplete)
        #expect(!LibrarySearchCoverage(
            totalDocuments: 4, documentsWithCachedContent: 4, incompleteGistCount: 1
        ).isComplete)
        #expect(!LibrarySearchCoverage(
            totalDocuments: 4, documentsWithCachedContent: 4, staleResultCount: 1
        ).isComplete)
    }

    @Test func todayKeepsItsPinnedDateAndUnknownTaskProgress() throws {
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        let summary = LibraryTodaySummary(date: InterfaceFixtures.referenceDate, timeZone: zone)
        #expect(summary.progress == nil)
        #expect(summary.availability == .unknown)
        #expect(summary.excerpt == nil)
        let model = LibraryModel(today: summary)
        model.query = "something else"
        #expect(model.today == summary)
        #expect(LibraryTaskProgress(completed: 0, total: 0).total == 0)
    }

    @Test func todayDistinguishesEmptyExistingNotesFromMissingOnes() {
        let existing = LibraryTodaySummary(date: InterfaceFixtures.referenceDate, availability: .existing)
        let missing = LibraryTodaySummary(date: InterfaceFixtures.referenceDate, availability: .missing)
        #expect(existing.availability == .existing)
        #expect(existing.excerpt == nil)
        #expect(existing != missing)
    }

    @Test func todayCarriesOnlyTheSuppliedCachedExcerptAndProgress() {
        let summary = LibraryTodaySummary(
            date: InterfaceFixtures.referenceDate, progress: .init(completed: 1, total: 3),
            availability: .existing, excerpt: "Keep the thought.\nLeave space for the next one."
        )
        #expect(summary.excerpt == "Keep the thought.\nLeave space for the next one.")
        #expect(summary.progress == .init(completed: 1, total: 3))
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
