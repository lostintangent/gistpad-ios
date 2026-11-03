import Foundation
import Testing
@testable import Comments

@MainActor @Suite struct CommentsModelTests {
    @Test func postsRootAndQuotedCommentsAndKeepsARejectedDraft() async throws {
        let remote = FakeRemote()
        let model = try await loadedModel(remote)
        model.draft = "First"
        await model.post()
        #expect(model.comments?.map(\.body) == ["First"])
        #expect(model.draft.isEmpty)

        model.beginQuote("the passage", filename: "notes.md")
        model.draft = "About this"
        await remote.reject(true)
        await model.post()
        #expect(model.failure == .post)
        #expect(model.draft == "About this")
        #expect(model.target == .quote(text: "the passage", filename: "notes.md"))

        await remote.reject(false)
        await model.post()
        #expect(model.failure == nil)
        #expect(model.comments?.last?.body == "> the passage\n\nAbout this")
        #expect(model.threads.first?.quotedPassage?.quote == "the passage")
        #expect((model.target, model.draft) == (.root, ""))
    }

    @Test func repliesUseTheWebMarkerAndStopAtTwoLevels() async throws {
        let remote = FakeRemote([comment(1, "Root"), comment(2, "> [comment:1]\n\nReply")])
        let model = try await loadedModel(remote)
        model.beginReply(to: 2)
        model.draft = "Deeper"
        await model.post()
        #expect(model.comments?.last?.body == "> [comment:2]\n\nDeeper")
        let reply = try #require(model.threads.first?.replies.first)
        #expect(reply.canReply)
        let deepest = try #require(reply.replies.first)
        #expect(deepest.depth == 2 && !deepest.canReply)
    }

    @Test func editingKeepsTheHiddenPrefixAndReturnsTheUnsentComment() async throws {
        let remote = FakeRemote([comment(1, "> the passage\n\nBefore")])
        let model = try await loadedModel(remote)
        model.beginReply(to: 1)
        model.draft = "Unsent"

        model.beginEditing(1)
        #expect(model.draft == "Before")
        model.removeContext()
        #expect((model.target, model.draft) == (.reply(1), "Unsent"))

        model.beginEditing(1)
        model.draft = "After"
        await model.post()
        #expect(model.comments?.map(\.body) == ["> the passage\n\nAfter"])
        #expect((model.target, model.draft) == (.reply(1), "Unsent"))
    }

    @Test func deletingACommentKeepsItsRepliesAsThreads() async throws {
        let remote = FakeRemote([comment(1, "Root"), comment(2, "> [comment:1]\n\nReply")])
        let model = try await loadedModel(remote)
        await model.delete(1)
        #expect(model.threads.map(\.id) == [2])
        #expect(await remote.comments.map(\.id) == [2])
    }

    private func loadedModel(_ remote: FakeRemote) async throws -> CommentsModel {
        let model = CommentsModel(gistID: "gist", userID: 42, gistOwnerID: 42, remote: remote)
        await model.refresh()
        try #require(model.comments != nil)
        return model
    }
}

private func comment(_ id: Int64, _ body: String) -> GistComment {
    let date = Date(timeIntervalSince1970: Double(id))
    return GistComment(
        id: id, body: body, user: .init(id: 42, login: "me"), createdAt: date, updatedAt: date)
}

private actor FakeRemote: CommentsRemote {
    private(set) var comments: [GistComment]
    private var rejects = false

    init(_ comments: [GistComment] = []) { self.comments = comments }

    func reject(_ rejects: Bool) { self.rejects = rejects }

    func listComments(gistID: String) async throws -> [GistComment] { comments }

    func createComment(gistID: String, body: String) async throws -> GistComment {
        if rejects { throw URLError(.notConnectedToInternet) }
        let created = comment((comments.map(\.id).max() ?? 0) + 1, body)
        comments.append(created)
        return created
    }

    func updateComment(gistID: String, commentID: Int64, body: String) async throws -> GistComment {
        let updated = comment(commentID, body)
        comments = comments.map { $0.id == commentID ? updated : $0 }
        return updated
    }

    func deleteComment(gistID: String, commentID: Int64) async throws {
        comments.removeAll { $0.id == commentID }
    }
}
