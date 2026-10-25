import Foundation
import Testing

@testable import GistPadInterface

@Suite @MainActor
struct LibraryCollectionVisibilityTests {
    @Test func unknownCollectionsDoNotFlashBeforeTheFirstSnapshot() {
        let model = LibraryModel()
        #expect(model.visibleCollections == [.gists, .dailyNotes])
        model.snapshot.notes = publishedCollections
        #expect(model.visibleCollections == [.gists, .dailyNotes])
        model.replaceSnapshot(.init(notes: []))
        model.loadState = .ready
        #expect(model.visibleCollections == [.gists, .dailyNotes])
    }

    @Test func confirmedPublishedGistsRevealTheirCollectionsInNavigationOrder() {
        let model = LibraryModel()
        model.replaceSnapshot(.init(notes: publishedCollections))
        #expect(model.visibleCollections == [.gists, .dailyNotes, .starred, .archive])
    }

    @Test func localAndRecoveryRowsCannotRevealPublishedCollections() {
        var local = publishedCollections
        for index in local.indices { local[index].gistID = nil }
        let model = LibraryModel(snapshot: .init(notes: local), loadState: .ready)
        #expect(model.visibleCollections == [.gists, .dailyNotes])
    }

    @Test func collectionVisibilityUsesTheSameOwnershipAndArchiveRulesAsItsList() {
        let model = LibraryModel(snapshot: .init(notes: [
            .init(
                id: "archived-star", title: "Synthetic archived star", updatedAt: .distantPast,
                gistID: "archived-star", isStarred: true, isArchived: true),
            .init(
                id: "foreign-archive", title: "Synthetic foreign archive", updatedAt: .distantPast,
                gistID: "foreign-archive", isOwned: false, isArchived: true)
        ]))
        #expect(model.visibleCollections == [.gists, .dailyNotes, .archive])
        model.replaceSnapshot(.init(notes: [
            .init(
                id: "foreign-star", title: "Synthetic foreign star", updatedAt: .distantPast,
                gistID: "foreign-star", isOwned: false, isStarred: true)
        ]))
        #expect(model.visibleCollections == [.gists, .dailyNotes, .starred])
    }

    @Test func searchesAndTagFiltersDoNotChangeCollectionAvailability() {
        let model = LibraryModel(snapshot: .init(notes: publishedCollections))
        model.query = "No synthetic note matches"
        model.selectedTagIDs = ["missing"]
        model.searchState = .searching
        #expect(model.matchingNotes.isEmpty)
        #expect(model.visibleCollections == [.gists, .dailyNotes, .starred, .archive])
        model.searchState = .failed(message: "Synthetic search failure")
        #expect(model.visibleCollections == [.gists, .dailyNotes, .starred, .archive])
    }

    @Test(arguments: [LibraryLoadState.loading, .offline, .failed(message: "Synthetic read failure")])
    func knownNonemptyCollectionsRemainAvailableDuringRefreshAndReadFailure(state: LibraryLoadState) {
        let model = LibraryModel(snapshot: .init(notes: publishedCollections), loadState: state)
        #expect(model.visibleCollections == [.gists, .dailyNotes, .starred, .archive])
        model.replaceSnapshot(nil)
        #expect(model.visibleCollections == [.gists, .dailyNotes])
    }

    @Test(arguments: [LibraryCollection.starred, .archive])
    func anActiveCollectionStaysWhenItsLastGistLeavesUntilNavigationChanges(
        collection: LibraryCollection
    ) {
        let model = LibraryModel(snapshot: .init(notes: publishedCollections), loadState: .ready)
        model.collection = collection
        model.replaceSnapshot(.init(notes: []))
        #expect(model.visibleCollections.contains(collection))
        #expect(model.matchingNotes.isEmpty)
        model.collection = .dailyNotes
        #expect(model.visibleCollections == [.gists, .dailyNotes])
    }

    @Test func removingTheLastGistHidesAnInactiveCollection() {
        let model = LibraryModel(snapshot: .init(notes: publishedCollections), loadState: .ready)
        model.replaceSnapshot(.init(notes: publishedCollections.filter { !$0.isStarred }))
        #expect(model.visibleCollections == [.gists, .dailyNotes, .archive])
        model.replaceSnapshot(.init(notes: []))
        #expect(model.visibleCollections == [.gists, .dailyNotes])
    }

    private var publishedCollections: [LibraryNote] {
        [
            .init(
                id: "starred", title: "Synthetic starred note", updatedAt: .distantPast,
                gistID: "starred", isStarred: true),
            .init(
                id: "archived", title: "Synthetic archived note", updatedAt: .distantPast,
                gistID: "archived", isArchived: true)
        ]
    }
}
