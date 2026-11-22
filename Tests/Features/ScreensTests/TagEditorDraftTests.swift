import Testing
@testable import Screens
import Store

struct TagEditorDraftTests {
    private let tag = Tag(id: "ideas", name: "Ideas", colorHex: "#EBC85A")

    @Test func unchangedChoicesWriteNothing() {
        let draft = TagEditorDraft(gistID: "shape", tags: [tag], selectedTagIDs: [tag.id])
        #expect(draft.edits.isEmpty)
    }

    @Test func tagAndUntagAGist() {
        var draft = TagEditorDraft(gistID: "shape", tags: [tag], selectedTagIDs: [])
        draft.selectedTagIDs.insert(tag.id)
        #expect(draft.edits == [.setTag(gistID: "shape", tagID: tag.id, included: true)])
        draft.selectedTagIDs.remove(tag.id)
        #expect(draft.edits.isEmpty)
    }

    @Test func renameKeepsTheColorAndMembership() {
        var draft = TagEditorDraft(gistID: "shape", tags: [tag], selectedTagIDs: [tag.id])
        let duplicate = draft.upsert(.init(id: "other", name: " ideas "))
        #expect(!duplicate)
        let renamed = Tag(id: tag.id, name: "Useful ideas", colorHex: tag.colorHex)
        let didRename = draft.upsert(renamed)
        #expect(didRename)
        #expect(draft.edits == [.upsertTag(id: renamed.id, name: renamed.name, color: renamed.colorHex)])
        #expect(draft.selectedTagIDs == [tag.id])
    }

    @Test func deletingATagRemovesItOnceWithoutMembershipWrites() {
        var draft = TagEditorDraft(gistID: "shape", tags: [tag], selectedTagIDs: [tag.id])
        draft.delete(tag)
        #expect(draft.edits == [.deleteTag(id: tag.id)])
        let new = Tag(id: "new", name: "New")
        _ = draft.upsert(new)
        draft.delete(new)
        #expect(draft.edits == [.deleteTag(id: tag.id)])
    }
}
