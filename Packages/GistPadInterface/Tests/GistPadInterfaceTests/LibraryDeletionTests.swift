#if os(iOS)
import Foundation
import Testing

@testable import GistPadInterface

@MainActor
struct LibraryDeletionTests {
    @Test(arguments: [
        (false, false, false), (false, false, true),
        (false, true, false), (false, true, true),
        (true, false, false), (true, false, true),
        (true, true, false), (true, true, true),
    ])
    func deletionRequiresOwnershipAndAnAppCallbackForPublishedAndLocalNotes(
        owned: Bool, published: Bool, supported: Bool
    ) {
        let note = LibraryNote(
            id: "gist/日本語.md", title: "A thought", updatedAt: .now,
            gistID: published ? "gist" : nil, isOwned: owned, canDeleteFromGitHub: published)
        var targets: [String] = []
        var actions = LibraryActions(refresh: {}, create: {}, today: {})
        if supported { actions.delete = { targets.append($0) } }
        let action = actions.deletionAction(for: note)
        #expect((action != nil) == (owned && supported))
        #expect(targets.isEmpty)
        action?()
        #expect(targets == (owned && supported ? [note.id] : []))
    }

    @Test func unpublishedLocalRowsOfferOnlyALocalDeletionCallback() {
        let note = LibraryNote(id: UUID().uuidString, title: "A local draft", updatedAt: .now)
        var targets: [String] = []
        var actions = LibraryActions(refresh: {}, create: {}, today: {})
        actions.delete = { targets.append($0) }
        #expect(note.isOwned)
        #expect(!note.canDeleteFromGitHub)
        let delete = actions.deletionAction(for: note)
        #expect(delete != nil)
        delete?()
        #expect(targets == [note.id])
    }

    @Test func recoveryRowsOfferOnlyALocalDeletionCallback() {
        let note = LibraryNote(
            id: UUID().uuidString, title: "A local copy", updatedAt: nil, isRecovery: true)
        var targets: [String] = []
        var actions = LibraryActions(refresh: {}, create: {}, today: {})
        actions.delete = { targets.append($0) }
        #expect(!note.canDeleteFromGitHub)
        let delete = actions.deletionAction(for: note)
        #expect(delete != nil)
        delete?()
        #expect(targets == [note.id])
    }
}
#endif
