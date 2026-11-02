import Foundation
import Testing
@testable import GistPadInterface

@MainActor
struct LibraryStateTests {
    private let library = InterfaceFixtures.library

    @Test func sectionsFollowOwnershipAndArchiveAndCountUniqueGists() {
        let model = LibraryModel(snapshot: library, loadState: .ready)
        model.snapshot.notes.append(.init(id: "shape/Ideas.md", title: "Ideas", updatedAt: nil, gistID: "shape"))
        #expect(model.unfilteredNotes(in: .gists).map(\.id) == ["shape", "weekend", "words", "mixed", "shape/Ideas.md"])
        #expect(model.unfilteredNotes(in: .dailyNotes).map(\.id) == ["daily"])
        #expect(model.unfilteredNotes(in: .starred).map(\.id) == ["starred"])
        #expect(model.unfilteredNotes(in: .archive).map(\.id) == ["archived"])
        model.query = "no matching title"
        model.selectedTagIDs = ["design"]
        #expect(model.mainGistCount == 4)
        #expect(model.count(in: .starred) == 1)
        #expect(model.count(in: .archive) == 1)
    }

    @Test func aSectionAppearsWithItsFirstGistAndHidesWithItsLast() {
        let model = LibraryModel(snapshot: .init(notes: []), loadState: .ready)
        #expect(model.secondaryCollections.isEmpty)
        model.replaceSnapshot(library)
        #expect(model.secondaryCollections == [.dailyNotes, .starred, .archive])
        model.replaceSnapshot(.init(notes: library.notes.filter { !$0.isArchived }))
        #expect(model.secondaryCollections == [.dailyNotes, .starred])
    }

    @Test func tagsUseANDAndTitleSearchIsLocalized() {
        let model = LibraryModel(snapshot: library, loadState: .ready)
        model.selectedTagIDs = ["ideas", "design"]
        #expect(model.matchingNotes.map(\.id) == ["shape"])
        model.query = "  NOTEBOOK\n"
        #expect(model.matchingNotes.map(\.id) == ["shape"])
        model.query = "weekend"
        #expect(model.matchingNotes.isEmpty)
        model.clearFilters()
        #expect(model.matchingNotes.map(\.id) == ["shape", "weekend", "words", "mixed"])
    }

    @Test func eachTagCountsTheGistsItsFilterShows() {
        let model = LibraryModel(snapshot: library, loadState: .ready)
        for tag in library.tags {
            model.selectedTagIDs = [tag.id]
            #expect(model.gistCount(tagged: tag.id) == model.resultGistCount)
        }
    }

    @Test func searchResultsKeepTheirOrderAndLandInOneSectionEach() {
        let model = LibraryModel(snapshot: library, loadState: .ready)
        let results = library.notes.reversed().map(\.self)
        model.query = "words only in the body"
        model.searchState = .results(notes: results)
        #expect(model.matchingNotes == results)
        #expect(model.matchingNotes(in: .gists).map(\.id) == ["mixed", "words", "weekend", "shape"])
        #expect(model.matchingNotes(in: .starred).map(\.id) == ["starred"])
        let grouped = LibraryCollection.allCases.flatMap { model.matchingNotes(in: $0) }
        #expect(Set(grouped.map(\.id)) == Set(results.map(\.id)))
        #expect(grouped.count == results.count)
    }

    @Test func theDailyCountIgnoresFilters() {
        var snapshot = library
        snapshot.dailyNoteCount = 12
        let model = LibraryModel(snapshot: snapshot, loadState: .ready)
        model.query = "no matching day"
        model.searchState = .results(notes: [])
        #expect(model.count(in: .dailyNotes) == 12)
    }

    @Test func dailyRowsListOverdueFirstThenTheNewestDay() {
        let today = InterfaceFixtures.referenceDate
        let notes: [LibraryNote] = [
            .init(id: "today", title: "Today", updatedAt: .now, gistID: "daily", isDailyNote: true, dailyDate: today),
            .init(id: "old", title: "Old", updatedAt: .now, gistID: "daily", isDailyNote: true,
                  isOverdue: true, dailyDate: today.addingTimeInterval(-172_800)),
            .init(id: "yesterday", title: "Yesterday", updatedAt: .distantPast, gistID: "daily", isDailyNote: true,
                  isOverdue: true, dailyDate: today.addingTimeInterval(-86_400))
        ]
        let model = LibraryModel(snapshot: .init(notes: notes, dailyNoteCount: 3))
        #expect(model.unfilteredNotes(in: .dailyNotes).map(\.id) == ["yesterday", "old", "today"])
        model.query = "body match"
        model.searchState = .results(notes: notes)
        #expect(model.matchingNotes(in: .dailyNotes).map(\.id) == ["yesterday", "old", "today"])
    }

    @Test func todayIsReachableFromCacheBeforeGitHubAnswers() {
        let model = LibraryModel()
        model.snapshot.notes = [
            .init(id: "local-day", title: "Today", updatedAt: nil, isDailyNote: true,
                  dailyDate: InterfaceFixtures.referenceDate)
        ]
        #expect(model.count(in: .dailyNotes) == nil)
        #expect(model.secondaryCollections == [.dailyNotes])
        #expect(model.unfilteredNotes(in: .dailyNotes).map(\.id) == ["local-day"])
    }

    @Test func todaysBadgeShowsOnlyForAnExistingDayWithKnownTasks() {
        var today = LibraryTodaySummary(progress: .init(completed: 1, total: 4), availability: .existing)
        #expect(today.unfinishedTaskCount == 3)
        today.progress = nil
        #expect(today.unfinishedTaskCount == nil)
        today = LibraryTodaySummary(progress: .init(completed: 1, total: 4), availability: .missing)
        #expect(today.unfinishedTaskCount == nil)
    }

    @Test func theOpenGistStaysOpenWhenAFilterHidesItsRow() {
        let model = LibraryModel(snapshot: library, loadState: .ready)
        model.selectedNoteID = "shape"
        model.selectedTagIDs = ["personal"]
        #expect(!model.matchingNotes.contains { $0.id == "shape" })
        #expect(model.selectedNoteID == "shape")
    }

    @Test func readOnlyGistsCantBeEdited() {
        #expect(NoteAccess.editable.canEdit)
        #expect(!NoteAccess.readOnly.canEdit)
        #expect(!NoteAccess.truncated.canEdit)
    }

    @Test func aFailedPublishOffersSaveEvenWithAutosaveOn() {
        #expect(NoteSaveState.cloudFailure(message: "Offline").showsManualSave(isAutoSaveEnabled: true))
        #expect(!NoteSaveState.savedLocally.showsManualSave(isAutoSaveEnabled: true))
    }
}
