import Foundation
import Testing
@testable import GistPadComments

@Suite struct CommentThreadTests {
    @Test func rootsAndRepliesAreNewestFirstWithStableTies() throws {
        let comments = [
            comment(1, date: 1), comment(2, date: 2),
            comment(3, date: 3, parent: 1), comment(4, date: 4, parent: 1),
            comment(5, date: 4, parent: 1)
        ]
        let threads = GistCommentThread.build(from: comments)
        #expect(threads.map(\.id) == [2, 1])
        let root = try #require(threads.last)
        #expect(root.replies.map(\.id) == [4, 5, 3])
        #expect(root.canReply)
        #expect(root.replies.allSatisfy { $0.depth == 1 && $0.canReply })
    }

    @Test func importedDeeperRepliesStayVisibleAtTwoLevels() throws {
        let threads = GistCommentThread.build(from: [
            comment(1), comment(2, parent: 1), comment(3, parent: 2),
            comment(4, parent: 3), comment(5, parent: 4)
        ])
        let firstReply = try #require(threads.first?.replies.first)
        #expect(firstReply.replies.map(\.id) == [5, 4, 3])
        #expect(firstReply.replies.allSatisfy { $0.depth == 2 && !$0.canReply && $0.replies.isEmpty })
        #expect(firstReply.replies.first?.comment.parsedBody.parentID == 4)
        #expect(flatten(threads).sorted() == [1, 2, 3, 4, 5])
    }

    @Test func deletedParentsAndSelfReferencesBecomeVisibleRoots() {
        let threads = GistCommentThread.build(from: [
            comment(1, parent: 99), comment(2, parent: 1), comment(3, parent: 3)
        ])
        #expect(threads.map(\.id) == [3, 1])
        #expect(threads.last?.replies.map(\.id) == [2])
        #expect(threads.last?.quotedPassage == nil)
    }

    @Test func cyclesCannotHideCommentsOrRecurseForever() {
        let threads = GistCommentThread.build(from: [
            comment(1, parent: 2), comment(2, parent: 3), comment(3, parent: 1),
            comment(4, parent: 2)
        ])
        #expect(threads.count == 1)
        #expect(flatten(threads).sorted() == [1, 2, 3, 4])
        #expect(threads.first?.depth == 0)
    }

    @Test func repeatedIDsKeepTheLatestEditedBodyOnlyOnce() {
        let first = comment(1, body: "> passage\n\nBefore", date: 1)
        let edited = GistComment(
            id: 1, body: "> passage\n\nAfter", user: nil,
            createdAt: first.createdAt, updatedAt: .init(timeIntervalSince1970: 10))
        let threads = GistCommentThread.build(from: [first, edited, first])
        #expect(threads.count == 1)
        #expect(threads.first?.comment.body == edited.body)
        #expect(threads.first?.quotedPassage == .init(commentID: 1, quote: "passage"))
    }

    @Test func longImportedChainsDoNotUseUnboundedRecursion() {
        let comments = (1...10_000).map { value in
            comment(Int64(value), parent: value == 1 ? nil : Int64(value - 1))
        }
        let threads = GistCommentThread.build(from: comments)
        #expect(flatten(threads).count == comments.count)
        #expect(threads.first?.replies.first?.replies.count == 9_998)
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

    private func flatten(_ threads: [GistCommentThread]) -> [Int64] {
        threads.flatMap { [$0.id] + flatten($0.replies) }
    }
}
