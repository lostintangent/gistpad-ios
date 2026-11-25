import Comments
import Store
import Testing

@testable import Model

struct CommentsTests {
    @Test func `A comment or a quote posts, and one GitHub turns down keeps its draft`() async throws {
        let (phone, model) = try await conversation()
        model.draft = "First"
        await model.post()
        #expect(model.comments?.map(\.body) == ["First"])
        #expect(model.draft.isEmpty)

        model.beginQuote("the passage", filename: "notes.md")
        model.draft = "About this"
        phone.goOffline()
        await model.post()
        #expect(model.failure?.request == .post)
        #expect(model.failure?.reason == Failure("GitHub couldn’t be reached.", action: .tryAgain))
        #expect(model.draft == "About this")
        #expect(model.target == .quote(text: "the passage", filename: "notes.md"))

        phone.goOnline()
        await model.post()
        #expect(model.failure == nil)
        #expect(model.comments?.last?.body == "> the passage\n\nAbout this")
        #expect(model.threads.compactMap(\.quotedPassage?.quote) == ["the passage"])
        #expect((model.target, model.draft) == (.root, ""))
    }

    @Test func `A reply uses the web's marker and stops two levels down`() async throws {
        let (_, model) = try await conversation(["Root", "> [comment:1]\n\nReply"])
        model.beginReply(to: 2)
        model.draft = "Deeper"
        await model.post()
        #expect(model.comments?.last?.body == "> [comment:2]\n\nDeeper")
        let reply = try #require(model.threads.first?.replies.first)
        #expect(reply.canReply)
        let deepest = try #require(reply.replies.first)
        #expect(!deepest.canReply)
    }

    @Test func `Editing keeps the hidden quote and gives back the comment I hadn't sent`() async throws {
        let (_, model) = try await conversation(["> the passage\n\nBefore"])
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

    @Test func `Deleting a comment keeps its replies, and a delete GitHub didn't get tries again`() async throws {
        let (phone, model) = try await conversation(["Root", "> [comment:1]\n\nReply"])
        phone.goOffline()
        await model.delete(1)
        #expect(model.failure?.request == .delete(1))
        #expect(model.threads.map(\.id) == [1])

        phone.goOnline()
        await model.retry()
        #expect(model.failure == nil)
        #expect(model.threads.map(\.id) == [2])
        await model.refresh()
        #expect(model.comments?.map(\.id) == [2])
    }

    @Test func `A load GitHub refuses says why, apart from what I post`() async throws {
        let (phone, model) = try await conversation(["Root"], loaded: false)
        phone.github.intercept { _ in .init(status: 401) }
        await model.refresh()
        #expect(model.comments == nil)
        #expect(model.refreshFailure == Failure("GitHub needs you to sign in again.", action: .reconnect))
        #expect(model.failure == nil)

        phone.goOnline()
        await model.refresh()
        #expect(model.refreshFailure == nil)
        #expect(model.comments?.map(\.body) == ["Root"])
    }

    /// The gist's conversation as the signed-in account, loaded unless `loaded` is false.
    private func conversation(
        _ comments: [String] = [], loaded: Bool = true
    ) async throws -> (Phone, CommentsModel) {
        let phone = try await Phone {
            $0.addGist(id: "gist", description: "Notes", files: ["notes.md": "the passage"], comments: comments)
        }
        await phone.launch()
        let gist = try #require(phone.github.gists.first)
        let model = try #require(phone.model.comments(for: gist))
        if loaded {
            await model.refresh()
            try #require(model.comments != nil)
        }
        return (phone, model)
    }
}
