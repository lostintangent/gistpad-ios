import Foundation

public struct CommentConversationScope: Codable, Equatable, Hashable, Sendable {
    public let accountID: UUID
    public let gistID: String

    public init(accountID: UUID, gistID: String) {
        self.accountID = accountID
        self.gistID = gistID
    }
}

public struct CapturedCommentQuote: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let filename: String
    public let text: String

    public init(id: UUID = UUID(), filename: String, text: String) {
        self.id = id
        self.filename = filename
        self.text = text
    }
}

public enum CommentComposerTarget: Codable, Equatable, Sendable {
    case root
    case quote(CapturedCommentQuote)
    case reply(commentID: Int64)
    case edit(commentID: Int64, originalBody: String)

    public var storageKey: String {
        switch self {
        case .root: "root"
        case .quote(let quote): "quote/\(quote.id)"
        case .reply(let id): "reply/\(id)"
        case .edit(let id, _): "edit/\(id)"
        }
    }
}

public struct CommentComposerDraft: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let target: CommentComposerTarget
    public var text: String
    public var generation: UInt64

    public init(
        id: UUID = UUID(), target: CommentComposerTarget = .root,
        text: String = "", generation: UInt64 = 0
    ) {
        self.id = id
        self.target = target
        self.text = text
        self.generation = generation
    }
}

public enum CommentDraftSaveState: Equatable, Sendable {
    case notSaved
    case saving
    case saved
    case failed
}

public enum CommentRemoteFailure: Error, Codable, Equatable, Sendable {
    case network
    case invalidRequest
    case authentication
    case forbidden
    case notFound
    case http(status: Int, retryAfter: Date?)
    case invalidResponse

    public var retryAfter: Date? {
        if case .http(_, let deadline) = self { deadline } else { nil }
    }

    var definitelyRejectedMutation: Bool {
        switch self {
        case .invalidRequest, .authentication, .forbidden, .notFound: true
        case .http(let status, _): (400..<500).contains(status) && status != 408
        case .network, .invalidResponse: false
        }
    }
}

public enum CommentConversationProblem: Error, Equatable, Sendable {
    case remote(CommentRemoteFailure)
    case localStorage
    case missingTarget(Int64)
    case replyDepthLimit
    case notAllowed
    case commentChanged
    case emptyBody
    case invalidSelection
    case busy
    case unresolvedMutation
    case unconfirmedMutation
    case existingRootDraft
}

public enum CommentMutationOperation: Codable, Equatable, Sendable {
    case create(body: String)
    case edit(commentID: Int64, body: String, originalBody: String)
    case delete(commentID: Int64)
}

public struct PendingCommentMutation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let operation: CommentMutationOperation
    public let draftID: UUID?
    public let draftGeneration: UInt64?
    public let baselineIDs: Set<Int64>
    public let authorID: Int64
    public var acknowledgedComment: GistComment?
    public var acknowledgedDeletion: Bool

    public init(
        id: UUID = UUID(), operation: CommentMutationOperation,
        draftID: UUID?, draftGeneration: UInt64?, baselineIDs: Set<Int64>, authorID: Int64
    ) {
        self.id = id
        self.operation = operation
        self.draftID = draftID
        self.draftGeneration = draftGeneration
        self.baselineIDs = baselineIDs
        self.authorID = authorID
        acknowledgedComment = nil
        acknowledgedDeletion = false
    }

    var isAcknowledged: Bool { acknowledgedComment != nil || acknowledgedDeletion }

    enum CodingKeys: String, CodingKey {
        case id, operation, draftID, draftGeneration, baselineIDs, authorID
        case acknowledgedComment, acknowledgedDeletion
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(operation, forKey: .operation)
        try container.encodeIfPresent(draftID, forKey: .draftID)
        try container.encodeIfPresent(draftGeneration, forKey: .draftGeneration)
        try container.encode(baselineIDs.sorted(), forKey: .baselineIDs)
        try container.encode(authorID, forKey: .authorID)
        try container.encodeIfPresent(acknowledgedComment, forKey: .acknowledgedComment)
        try container.encode(acknowledgedDeletion, forKey: .acknowledgedDeletion)
    }
}

public enum CommentMutationState: Equatable, Sendable {
    case idle
    case working
    case failed(CommentConversationProblem)
    case needsRefresh
    case localCompletionFailed
}

public struct CommentComposerState: Equatable, Sendable {
    public let draft: CommentComposerDraft
    public let saveState: CommentDraftSaveState
    public let problem: CommentConversationProblem?
    public let canEdit: Bool
    public let canPost: Bool

    public init(
        draft: CommentComposerDraft, saveState: CommentDraftSaveState,
        problem: CommentConversationProblem? = nil, canEdit: Bool, canPost: Bool
    ) {
        self.draft = draft
        self.saveState = saveState
        self.problem = problem
        self.canEdit = canEdit
        self.canPost = canPost
    }
}

public struct CommentDraftArchive: Codable, Equatable, Sendable {
    public let scope: CommentConversationScope
    public var revision: UInt64
    public var drafts: [CommentComposerDraft]
    public var activeDraftID: UUID
    public var pendingMutation: PendingCommentMutation?

    public init(scope: CommentConversationScope) {
        let draft = CommentComposerDraft()
        self.scope = scope
        revision = 0
        drafts = [draft]
        activeDraftID = draft.id
        pendingMutation = nil
    }
}

public enum CommentStoreFailure: Error, Equatable, Sendable {
    case unavailable
    case invalidRecord
    case staleWrite
}

public protocol CommentConversationStore: Sendable {
    func loadDrafts(scope: CommentConversationScope) async throws -> CommentDraftArchive?
    func saveDrafts(_ archive: CommentDraftArchive) async throws
}

public protocol CommentConversationRemote: Sendable {
    func listComments(gistID: String) async throws(CommentRemoteFailure) -> [GistComment]
    func comment(gistID: String, commentID: Int64) async throws(CommentRemoteFailure) -> GistComment
    func createComment(gistID: String, body: String) async throws(CommentRemoteFailure) -> GistComment
    func updateComment(
        gistID: String, commentID: Int64, body: String
    ) async throws(CommentRemoteFailure) -> GistComment
    func deleteComment(gistID: String, commentID: Int64) async throws(CommentRemoteFailure)
}
