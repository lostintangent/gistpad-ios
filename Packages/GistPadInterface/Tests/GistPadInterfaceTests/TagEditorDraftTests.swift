import Testing
@testable import GistPadInterface

struct TagEditorDraftTests {
    private let tag = GistPadInterface.Tag(id: "ideas", name: "Ideas", colorHex: "#EBC85A")

    @Test func unchangedChoicesWriteNothing() {
        let draft = TagEditorDraft(tags: [tag], selectedTagIDs: [tag.id])
        #expect(draft.edits.isEmpty)
    }

    @Test func tagAndUntagAGist() {
        var draft = TagEditorDraft(tags: [tag], selectedTagIDs: [])
        draft.selectedTagIDs.insert(tag.id)
        #expect(draft.edits == [.setMembership(tagID: tag.id, included: true)])
        draft.selectedTagIDs.remove(tag.id)
        #expect(draft.edits.isEmpty)
    }

    @Test func renameKeepsTheColorAndMembership() throws {
        var draft = TagEditorDraft(tags: [tag], selectedTagIDs: [tag.id])
        #expect(throws: TagEditingError.self) { try draft.upsert(.init(id: "other", name: " ideas ")) }
        #expect(throws: TagEditingError.self) { try draft.upsert(.init(id: "other", name: " \n")) }
        let renamed = GistPadInterface.Tag(id: tag.id, name: "Useful ideas", colorHex: tag.colorHex)
        try draft.upsert(renamed)
        #expect(draft.edits == [.upsert(renamed)])
        #expect(draft.selectedTagIDs == [tag.id])
    }

    @Test func deletingATagRemovesItOnceWithoutMembershipWrites() throws {
        var draft = TagEditorDraft(tags: [tag], selectedTagIDs: [tag.id])
        draft.delete(tag)
        #expect(draft.edits == [.delete(tagID: tag.id)])
        let new = GistPadInterface.Tag(id: "new", name: "New")
        try draft.upsert(new)
        draft.delete(new)
        #expect(draft.edits == [.delete(tagID: tag.id)])
    }
}
