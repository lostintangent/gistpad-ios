import Foundation
import Testing
@testable import GistPadInterface

struct TagEditingTests {
    private let tag = LibraryTag(id: "ideas", name: "Ideas", colorHex: "#EBC85A")

    @Test func unchangedChoicesDoNotWrite() {
        let draft = TagEditorDraft(tags: [tag], selectedTagIDs: [tag.id])
        #expect(draft.edits.isEmpty)
    }

    @Test func membershipEditsAreExplicitAndReversible() {
        var draft = TagEditorDraft(tags: [tag], selectedTagIDs: [])
        draft.selectedTagIDs.insert(tag.id)
        #expect(draft.edits == [.setMembership(tagID: tag.id, included: true)])
        draft.selectedTagIDs.remove(tag.id)
        #expect(draft.edits.isEmpty)
    }

    @Test func newTagIDsAndRetryOperationsRemainStable() throws {
        var draft = TagEditorDraft(tags: [], selectedTagIDs: [])
        try draft.upsert(tag)
        let edits = draft.edits
        #expect(edits == [.upsert(tag), .setMembership(tagID: tag.id, included: true)])
        #expect(draft.edits == edits)
        #expect(draft.selectedTagIDs == [tag.id])
    }

    @Test func deletingANewTagNeverTouchesTheAccount() throws {
        var draft = TagEditorDraft(tags: [], selectedTagIDs: [])
        try draft.upsert(tag)
        draft.delete(tag)
        #expect(draft.edits.isEmpty)
    }

    @Test func globalDeletionDoesNotAlsoEmitAMembershipRequest() {
        var draft = TagEditorDraft(tags: [tag], selectedTagIDs: [tag.id])
        draft.delete(tag)
        #expect(draft.edits == [.delete(tagID: tag.id)])
    }

    @Test func renamePreservesIDColorAndMembership() throws {
        var draft = TagEditorDraft(tags: [tag], selectedTagIDs: [tag.id])
        let renamed = LibraryTag(id: tag.id, name: "Useful ideas", colorHex: tag.colorHex)
        try draft.upsert(renamed)
        #expect(draft.edits == [.upsert(renamed)])
        #expect(draft.selectedTagIDs == [tag.id])
    }

    @Test func invalidNamesStayExplicitAndDoNotChangeTheDraft() throws {
        var draft = TagEditorDraft(tags: [tag], selectedTagIDs: [])
        #expect(throws: TagEditingError.self) {
            try draft.upsert(.init(id: "other", name: " ideas "))
        }
        #expect(throws: TagEditingError.self) {
            try draft.upsert(.init(id: "other", name: " \n"))
        }
        #expect(draft.tags == [tag])
        #expect(draft.edits.isEmpty)
    }

    @Test func revertingMembershipAfterAPartialFailureStillReconcilesTheAccount() {
        var draft = TagEditorDraft(tags: [tag], selectedTagIDs: [])
        draft.selectedTagIDs.insert(tag.id)
        draft.recordAttempt(draft.edits)
        draft.selectedTagIDs.remove(tag.id)
        #expect(draft.edits == [.setMembership(tagID: tag.id, included: false)])
    }

    @Test func deletingATagAfterAnUncertainUpsertEmitsCleanupForTheSameID() throws {
        var draft = TagEditorDraft(tags: [], selectedTagIDs: [])
        try draft.upsert(tag)
        draft.recordAttempt(draft.edits)
        draft.delete(tag)
        #expect(draft.edits == [.delete(tagID: tag.id)])
    }

    @Test func revertingAnAttemptedRenameStillRestoresItsOriginalMetadata() throws {
        var draft = TagEditorDraft(tags: [tag], selectedTagIDs: [])
        try draft.upsert(.init(id: tag.id, name: "Renamed", colorHex: nil))
        draft.recordAttempt(draft.edits)
        try draft.upsert(tag)
        #expect(draft.edits == [.upsert(tag)])
        #expect(draft.hasAttemptedChanges)
    }
}
