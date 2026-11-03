import Foundation
import Testing
@testable import Comments

@Suite struct CommentThreadTests {
    @Test func threadsAreNewestFirstAndRepliesWithoutAParentBecomeThreads() throws {
        let threads = GistCommentThread.build(from: [
            comment(1, date: 1), comment(2, date: 2),
            comment(3, date: 3, parent: 1), comment(4, date: 4, parent: 1),
            comment(5, date: 4, parent: 1), comment(6, date: 0, parent: 99)
        ])
        #expect(threads.map(\.id) == [2, 1, 6])
        #expect(threads[1].replies.map(\.id) == [4, 5, 3])
        #expect(threads[1].replies.allSatisfy { $0.depth == 1 && $0.canReply })
    }

    @Test func permissionsDistinguishAuthorshipFromGistOwnership() {
        let authored = GistComment(
            id: 1, body: "Body", user: .init(id: 42, login: "author"),
            createdAt: .distantPast, updatedAt: .distantPast)
        #expect(authored.canEdit(as: 42))
        #expect(!authored.canEdit(as: 7))
        #expect(authored.canDelete(as: 42, gistOwnerID: 7))
        #expect(authored.canDelete(as: 7, gistOwnerID: 7))
        #expect(!authored.canDelete(as: nil, gistOwnerID: nil))
        #expect(!authored.canDelete(as: 8, gistOwnerID: 7))
        #expect(!comment(2).canEdit(as: 42))
        #expect(comment(2).canDelete(as: 7, gistOwnerID: 7))
    }

    private func comment(
        _ id: Int64, body: String? = nil, date: TimeInterval? = nil, parent: Int64? = nil
    ) -> GistComment {
        let body = body ?? parent.map { "> [comment:\($0)]\n\nReply" } ?? "Body"
        let date = Date(timeIntervalSince1970: date ?? Double(id))
        return GistComment(id: id, body: body, user: nil, createdAt: date, updatedAt: date)
    }
}
