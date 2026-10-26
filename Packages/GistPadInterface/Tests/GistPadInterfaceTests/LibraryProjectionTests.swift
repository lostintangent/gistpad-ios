import Foundation
import Testing
@testable import GistPadInterface

@MainActor
struct LibraryProjectionTests {
    @Test func homeCountDoesNotIncludeCollectionsOverlapsOrUnpublishedCopies() {
        let model = LibraryModel()
        #expect(model.mainGistCount == nil)
        model.replaceSnapshot(.init(notes: [
            .init(id: "one", title: "One", updatedAt: nil, gistID: "one", isPinned: true, isStarred: true),
            .init(id: "another-file", title: "Another file", updatedAt: nil, gistID: "one"),
            .init(id: "daily/day.md", title: "A day", updatedAt: nil, gistID: "daily", isDailyNote: true),
            .init(id: "archived", title: "Finished", updatedAt: nil, gistID: "archived", isArchived: true),
            .init(id: "foreign", title: "A discovery", updatedAt: nil, gistID: "foreign", isOwned: false, isStarred: true),
            .init(id: "local", title: "On this iPhone", updatedAt: nil)
        ], dailyNoteCount: 1))
        #expect(model.mainGistCount == 1)
        #expect(model.count(in: .dailyNotes) == 1)
        #expect(model.count(in: .starred) == 2)
        #expect(model.count(in: .archive) == 1)
        #expect(model.secondaryCollections == [.dailyNotes, .starred, .archive])
        model.snapshot.dailyNoteCount = nil
        #expect(model.count(in: .dailyNotes) == nil)
        #expect(model.secondaryCollections.contains(.dailyNotes))
        model.loadState = .offline
        #expect(model.secondaryCollections == [.dailyNotes, .starred, .archive])
        model.replaceSnapshot(nil)
        #expect(model.secondaryCollections.isEmpty)
    }

    @Test func oneAllCollectionResultAppearsOnceWithoutResortingOrdinaryMatches() {
        let notes: [LibraryNote] = [
            .init(id: "second", title: "Second", updatedAt: .distantPast, gistID: "second", isPinned: true, isStarred: true),
            .init(id: "first", title: "First", updatedAt: .now, gistID: "first"),
            .init(id: "foreign", title: "Discovery", updatedAt: nil, gistID: "foreign", isOwned: false, isStarred: true),
            .init(id: "daily/day.md", title: "Day", updatedAt: nil, gistID: "daily", isDailyNote: true),
            .init(id: "archived", title: "Finished", updatedAt: nil, gistID: "archived", isArchived: true)
        ]
        let model = LibraryModel(snapshot: .init(notes: notes, dailyNoteCount: 1))
        #expect(model.unfilteredNotes(in: .starred).count == 2)
        model.query = "body-only match"
        model.searchState = .results(
            notes: notes, coverage: .init(totalDocuments: notes.count, documentsWithCachedContent: notes.count))
        #expect(model.matchingNotes(in: .gists).map(\.id) == ["second", "first"])
        #expect(model.matchingNotes(in: .dailyNotes).map(\.id) == ["daily/day.md"])
        #expect(model.matchingNotes(in: .starred).map(\.id) == ["foreign"])
        #expect(model.matchingNotes(in: .archive).map(\.id) == ["archived"])
        let grouped = LibraryCollection.allCases.flatMap { model.matchingNotes(in: $0) }
        #expect(grouped.count == notes.count)
        #expect(Set(grouped.map(\.id)) == Set(notes.map(\.id)))
    }

    @Test func dailyRowsKeepOverdueFirstThenNewestDayInBrowseAndSearch() {
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
        model.searchState = .results(notes: notes, coverage: .init(totalDocuments: 3, documentsWithCachedContent: 3))
        #expect(model.matchingNotes(in: .dailyNotes).map(\.id) == ["yesterday", "old", "today"])
    }
}
