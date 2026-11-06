import Foundation
import Sync
import Testing
@testable import Interface

@MainActor
struct LibraryStateTests {
    private let gists = SampleLibrary.gists
    private let tags = SampleLibrary.tags

    @Test func sectionsFollowOwnershipAndArchiveAndCountUniqueGists() {
        let state = LibraryState(gists: gists, tags: tags, loadState: .ready)
        state.gists.append(.init(id: "shape/Ideas.md", title: "Ideas", updatedAt: nil, gistID: "shape"))
        #expect(state.unfilteredGists(in: .gists).map(\.id) == ["shape", "weekend", "words", "mixed", "shape/Ideas.md"])
        #expect(state.unfilteredGists(in: .dailyNotes).map(\.id) == ["daily"])
        #expect(state.unfilteredGists(in: .starred).map(\.id) == ["starred"])
        #expect(state.unfilteredGists(in: .archived).map(\.id) == ["archived"])
        state.query = "no matching title"
        state.selectedTagIDs = ["design"]
        #expect(state.mainGistCount == 4)
        #expect(state.count(in: .starred) == 1)
        #expect(state.count(in: .archived) == 1)
    }

    @Test func aSectionAppearsWithItsFirstGistAndHidesWithItsLast() {
        let state = LibraryState(gists: [], loadState: .ready)
        #expect(state.secondarySections.isEmpty)
        state.replace(gists: gists, tags: tags)
        #expect(state.secondarySections == [.dailyNotes, .starred, .archived])
        state.replace(gists: gists.filter { !$0.isArchived }, tags: tags)
        #expect(state.secondarySections == [.dailyNotes, .starred])
    }

    @Test func tagsUseANDAndTitleSearchIsLocalized() {
        let state = LibraryState(gists: gists, tags: tags, loadState: .ready)
        state.selectedTagIDs = ["ideas", "design"]
        #expect(state.matchingGists.map(\.id) == ["shape"])
        state.query = "  GIST\n"
        #expect(state.matchingGists.map(\.id) == ["shape"])
        state.query = "weekend"
        #expect(state.matchingGists.isEmpty)
        state.clearFilters()
        #expect(state.matchingGists.map(\.id) == ["shape", "weekend", "words", "mixed"])
    }

    @Test func eachTagCountsTheGistsItsFilterShows() {
        let state = LibraryState(gists: gists, tags: tags, loadState: .ready)
        for tag in tags {
            state.selectedTagIDs = [tag.id]
            #expect(state.gistCount(tagged: tag.id) == state.resultGistCount)
        }
    }

    @Test func theDailyCountIgnoresFilters() {
        let state = LibraryState(gists: gists, tags: tags, dailyNoteCount: 12, loadState: .ready)
        state.query = "no matching day"
        #expect(state.count(in: .dailyNotes) == 12)
    }

    @Test func dailyRowsListOverdueFirstThenTheNewestDay() {
        let today = SampleLibrary.referenceDate
        let days: [GistItem] = [
            .init(id: "today", title: "Today", updatedAt: .now, gistID: "daily", isDailyNote: true, dailyDate: today),
            .init(id: "old", title: "Two days ago", updatedAt: .now, gistID: "daily", isDailyNote: true,
                  isOverdue: true, dailyDate: today.addingTimeInterval(-172_800)),
            .init(id: "yesterday", title: "Yesterday", updatedAt: .distantPast, gistID: "daily", isDailyNote: true,
                  isOverdue: true, dailyDate: today.addingTimeInterval(-86_400))
        ]
        let state = LibraryState(gists: days, dailyNoteCount: 3)
        #expect(state.unfilteredGists(in: .dailyNotes).map(\.id) == ["yesterday", "old", "today"])
        state.query = "day"
        #expect(state.matchingGists(in: .dailyNotes).map(\.id) == ["yesterday", "old", "today"])
    }

    @Test func todayIsReachableFromCacheBeforeGitHubAnswers() {
        let state = LibraryState()
        state.gists = [
            .init(id: "local-day", title: "Today", updatedAt: nil, isDailyNote: true,
                  dailyDate: SampleLibrary.referenceDate)
        ]
        #expect(state.count(in: .dailyNotes) == nil)
        #expect(state.secondarySections == [.dailyNotes])
        #expect(state.unfilteredGists(in: .dailyNotes).map(\.id) == ["local-day"])
    }

    @Test func theOpenGistStaysListedWithoutCountingAsAMatch() {
        let state = LibraryState(gists: gists, tags: tags, loadState: .ready)
        state.selectedID = "shape"
        state.selectedTagIDs = ["personal"]
        #expect(state.matchingGists.map(\.id) == ["shape", "weekend", "mixed"])
        #expect(state.resultGistCount == 2)
        #expect(state.hasMatches)

        state.query = "zzz"
        #expect(state.matchingGists.map(\.id) == ["shape"])
        #expect(!state.hasMatches)
    }

    @Test func aDailyNoteIsTitledByItsDayWithoutAFilename() throws {
        let days = ["2026-11-05.md", "2026-11-06.md"].map { GistDetails.File(id: $0, filename: $0) }
        let daily = GistDetails(
            title: DailyNote.gistDescription, files: days, selectedFileID: "2026-11-06.md", isDailyNote: true)
        let now = try #require(DailyNote.date(filename: "2026-11-06.md"))
        #expect(daily.displayTitle(now: now, locale: Locale(identifier: "en_US"), calendar: .current) == "Friday, Nov 6")
        #expect(daily.headerFilename == nil)
    }

    @Test func readOnlyGistsCantBeEdited() {
        #expect(FileAccess.editable.canEdit)
        #expect(!FileAccess.readOnly.canEdit)
    }

    @Test func aFailedPublishOffersPublishEvenWithAutosaveOn() {
        #expect(PublishState.failed(.network).showsPublish(isAutoSaveEnabled: true))
        #expect(!PublishState.failed(.readOnly).showsPublish(isAutoSaveEnabled: true))
        #expect(!PublishState.savedLocally.showsPublish(isAutoSaveEnabled: true))
        #expect(PublishState.savedToGitHub.showsPublish(isAutoSaveEnabled: false))
    }
}
