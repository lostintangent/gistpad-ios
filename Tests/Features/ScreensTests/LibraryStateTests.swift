import Foundation
import Store
import Testing
@testable import Screens

struct LibraryStateTests {
    private let gists = SampleLibrary.gists
    private let tags = SampleLibrary.tags

    @Test func sectionsFollowOwnershipAndArchiveAndCountUniqueGists() {
        let state = LibraryState(gists: gists, tags: tags)
        state.gists.append(.init(id: "shape/Ideas.md", title: "Ideas", updatedAt: nil, gistID: "shape"))
        #expect(state.matchingGists(in: .gists).map(\.id) == ["shape", "weekend", "words", "mixed", "shape/Ideas.md"])
        #expect(state.matchingGists(in: .dailyNotes).map(\.id) == ["daily"])
        #expect(state.matchingGists(in: .starred).map(\.id) == ["starred"])
        #expect(state.matchingGists(in: .archived).map(\.id) == ["archived"])
        state.query = "no matching title"
        state.selectedTagIDs = ["design"]
        #expect(state.count(in: .gists) == 4)
        #expect(state.count(in: .starred) == 1)
        #expect(state.count(in: .archived) == 1)
    }

    @Test func aSectionAppearsWithItsFirstGistAndHidesWithItsLast() {
        let state = LibraryState(gists: [])
        #expect(state.secondarySections.isEmpty)
        state.replace(gists: gists, tags: tags)
        #expect(state.secondarySections == [.dailyNotes, .starred, .archived])
        state.replace(gists: gists.filter { !$0.isArchived }, tags: tags)
        #expect(state.secondarySections == [.dailyNotes, .starred])
    }

    @Test func tagsUseANDAndTitleSearchIsLocalized() {
        let state = LibraryState(gists: gists, tags: tags)
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
        let state = LibraryState(gists: gists, tags: tags)
        for tag in tags {
            state.selectedTagIDs = [tag.id]
            #expect(state.gistCount(tagged: tag.id) == state.resultGistCount)
        }
    }

    @Test func theDailyCountIgnoresFilters() {
        let state = LibraryState(gists: gists, tags: tags, dailyNoteCount: 12)
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
        #expect(state.matchingGists(in: .dailyNotes).map(\.id) == ["yesterday", "old", "today"])
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
        #expect(state.matchingGists(in: .dailyNotes).map(\.id) == ["local-day"])
    }

    @Test func theOpenGistStaysListedWithoutCountingAsAMatch() {
        let state = LibraryState(gists: gists, tags: tags)
        state.selectedID = "shape"
        state.selectedTagIDs = ["personal"]
        #expect(state.matchingGists.map(\.id) == ["shape", "weekend", "mixed"])
        #expect(state.resultGistCount == 2)
        #expect(state.hasMatches)

        state.query = "zzz"
        #expect(state.matchingGists.map(\.id) == ["shape"])
        #expect(!state.hasMatches)
    }

    @Test func dateSectionsMoveWithTheModelsDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let state = LibraryState(
            gists: gists, tags: tags,
            today: DailyNote(day: .init(date: SampleLibrary.referenceDate.addingTimeInterval(-3_600), timeZone: .gmt)))
        #expect(state.dateSections(calendar: calendar).map(\.group) == [.today, .yesterday])
        state.today = DailyNote(day: .init(date: SampleLibrary.referenceDate, timeZone: .gmt))
        #expect(state.dateSections(calendar: calendar).map(\.group) == [.yesterday, .previousSevenDays])
    }

    @Test func aDailyNoteIsTitledByItsDayWithoutAFilename() throws {
        let daily = GistDetails(
            title: DailyNote.gistDescription, filenames: ["2026-11-05.md", "2026-11-06.md"],
            filename: "2026-11-06.md", isDailyNote: true)
        let now = try #require(DailyNote.date(filename: "2026-11-06.md"))
        #expect(daily.displayTitle(now: now, locale: Locale(identifier: "en_US"), calendar: .current) == "Friday, Nov 6")
        #expect(daily.headerFilename == nil)
    }
}

private enum SampleLibrary {
    static let referenceDate = Date(timeIntervalSince1970: 1_792_800_000)

    static let gists: [GistItem] = [
        GistItem(
            id: "shape", title: "The shape of a gist", updatedAt: referenceDate, gistID: "shape",
            isPinned: true, tagIDs: ["ideas", "design"], fileCount: 2
        ),
        GistItem(
            id: "weekend", title: "A slower weekend", updatedAt: referenceDate.addingTimeInterval(-3_600), gistID: "weekend",
            tagIDs: ["personal"]
        ),
        GistItem(
            id: "words", title: "Words worth keeping", updatedAt: referenceDate.addingTimeInterval(-86_400), gistID: "words",
            tagIDs: ["ideas"]
        ),
        GistItem(
            id: "mixed", title: "日本語のメモ · أفكار صغيرة", updatedAt: referenceDate.addingTimeInterval(-172_800), gistID: "mixed",
            tagIDs: ["personal"]
        ),
        GistItem(
            id: "daily", title: "Daily notes", updatedAt: referenceDate, gistID: "daily", isDailyNote: true
        ),
        GistItem(
            id: "starred", title: "An excellent Markdown field guide", updatedAt: referenceDate, gistID: "starred",
            owner: "notebook-friend", isOwned: false, isSecret: false, isStarred: true
        ),
        GistItem(
            id: "archived", title: "A finished chapter", updatedAt: referenceDate.addingTimeInterval(-604_800), gistID: "archived",
            isArchived: true
        )
    ]

    static let tags: [Store.Tag] = [
        .init(id: "ideas", name: "Ideas", colorHex: "#EBC85A"),
        .init(id: "design", name: "Design", colorHex: "#548C80"),
        .init(id: "personal", name: "Personal", colorHex: "#A88EB5")
    ]
}
