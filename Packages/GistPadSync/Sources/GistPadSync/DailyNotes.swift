import Foundation

public struct DailyNoteTarget: Codable, Equatable, Hashable, Sendable {
    public let filename: String
    public let timeZoneIdentifier: String

    public init(date: Date = .now, timeZone: TimeZone = .current) {
        filename = GistConventions.todayFilename(date: date, timeZone: timeZone)
        timeZoneIdentifier = timeZone.identifier
    }
}

/// A day's file in the daily notes gist, as the phone knows it: your draft once you've started the day
/// here, otherwise GitHub's cached copy.
public struct DailyNote: Codable, Equatable, Sendable {
    public let day: DailyNoteTarget
    /// The daily notes gist, once the phone knows it.
    public let gistID: String?
    /// Your draft of the day, once you've opened it on the phone.
    public let draftID: UUID?
    /// The day's Markdown, or nil when the phone has neither a draft nor a cached copy.
    public let text: String?
    /// Your draft's publish state.
    public let state: PublishState?

    public var date: Date? {
        DailyNotesIndex.parseDateFilename(
            day.filename, timeZone: TimeZone(identifier: day.timeZoneIdentifier) ?? .current)
    }

    public var tasks: [FileTask] { text.map(FileTask.tasks(in:)) ?? [] }
    public var progress: TaskProgress? { text.map(TaskProgress.init(markdown:)) }

    public init(
        day: DailyNoteTarget = DailyNoteTarget(), gistID: String? = nil, draftID: UUID? = nil,
        text: String? = nil, state: PublishState? = nil
    ) {
        self.day = day
        self.gistID = gistID
        self.draftID = draftID
        self.text = text
        self.state = state
    }

    /// What the library cache and your drafts say about `day`.
    public init(day: DailyNoteTarget = DailyNoteTarget(), cache: CachedLibrarySnapshot?, drafts: [DraftSnapshot]) {
        let gist = cache?.owned.first(where: \.isDailyNote)
        let draft = drafts.first {
            $0.filename == day.filename && ($0.gistID == nil
                ? $0.description == GistConventions.dailyNotesDescription : $0.gistID == gist?.id)
        }
        self.init(
            day: day, gistID: gist?.id, draftID: draft?.id,
            text: draft?.text ?? gist.flatMap { cache?.content(gist: $0, filename: day.filename) },
            state: draft?.state)
    }
}

public enum DailyNotesIndex {
    public static func parseDateFilename(_ filename: String, timeZone: TimeZone = .current) -> Date? {
        guard filename.range(of: #"^\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression) != nil else {
            return nil
        }
        let components = filename.dropLast(3).split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let requested = DateComponents(year: components[0], month: components[1], day: components[2])
        guard let result = calendar.date(from: requested) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: result)
        return actual == requested ? result : nil
    }
}

public enum DailyNotesError: Error, Equatable, Sendable {
    case pendingCreation(draftID: UUID)
}

public struct TodayNote: Equatable, Sendable {
    public let target: DailyNoteTarget
    public let gist: Gist?
    public let draft: DraftSnapshot
}

public actor DailyNotesService {
    private let accountID: UUID
    private let githubUserID: Int64
    private let client: GitHubClient
    private let store: DraftStore
    private let coordinator: SyncCoordinator
    private var pending: [String: Task<TodayNote, any Error>] = [:]

    public init(
        accountID: UUID, githubUserID: Int64,
        client: GitHubClient, store: DraftStore, coordinator: SyncCoordinator
    ) {
        self.accountID = accountID
        self.githubUserID = githubUserID
        self.client = client
        self.store = store
        self.coordinator = coordinator
    }

    public func openToday(
        target: DailyNoteTarget = DailyNoteTarget(), publishIfMissing: Bool = true
    ) async throws -> TodayNote {
        let key = "\(target.filename)/\(publishIfMissing)"
        if let task = pending[key] { return try await task.value }
        let task = Task { try await load(target: target, publishIfMissing: publishIfMissing) }
        pending[key] = task
        defer { pending[key] = nil }
        return try await task.value
    }

    public func stageToday(target: DailyNoteTarget = DailyNoteTarget()) async throws -> TodayNote {
        let cache = try await store.cachedLibrary(accountID: accountID)
        guard let gist = cache?.owned.first(where: \.isDailyNote) else {
            return try await openToday(target: target, publishIfMissing: false)
        }
        guard gist.owner?.id == githubUserID else { throw DraftError.readOnly }
        let local = try await store.drafts(accountID: accountID)
        if let existing = local.first(where: { $0.gistID == gist.id && $0.filename == target.filename }) {
            return TodayNote(target: target, gist: gist, draft: existing)
        }
        guard gist.truncated != true else {
            return try await openToday(target: target, publishIfMissing: false)
        }
        if gist.files[target.filename] != nil {
            guard let content = cache?.cachedContent(gist: gist, filename: target.filename),
                  content.isCurrent else {
                return try await openToday(target: target, publishIfMissing: false)
            }
            let draft = try await store.openDraft(
                accountID: accountID, githubUserID: githubUserID, gistID: gist.id,
                filename: target.filename, description: gist.description ?? "",
                content: content.text, revision: gist.revision)
            return TodayNote(target: target, gist: gist, draft: draft)
        }
        var template: String?
        if gist.files[GistConventions.templateFilename] != nil {
            guard let cached = cache?.cachedContent(gist: gist, filename: GistConventions.templateFilename),
                  cached.isCurrent else {
                return try await openToday(target: target, publishIfMissing: false)
            }
            template = cached.text
        }
        let draft = try await store.newFileDraft(
            accountID: accountID, githubUserID: githubUserID, gistID: gist.id,
            filename: target.filename, description: gist.description ?? "",
            text: GistConventions.dailyContent(template: template, dateFilename: target.filename))
        return TodayNote(target: target, gist: gist, draft: draft)
    }

    private func load(target: DailyNoteTarget, publishIfMissing: Bool) async throws -> TodayNote {
        let matches = try await client.listGists().filter(\.isDailyNote)
        guard let first = matches.first else {
            var draft = try await store.dailyGistDraft(
                accountID: accountID, githubUserID: githubUserID, target: target
            )
            if publishIfMissing { draft = try await coordinator.publish(id: draft.id, accountID: accountID) }
            let gist: Gist?
            if let id = draft.gistID { gist = try await client.gist(id: id) }
            else { gist = nil }
            return TodayNote(target: target, gist: gist, draft: draft)
        }
        let id = first.id
        let localDrafts = try await store.drafts(accountID: accountID)
        var existing = localDrafts.first {
            $0.gistID == id && $0.filename == target.filename
        }
        let pendingCreation = localDrafts.first {
            $0.gistID == nil && $0.description == GistConventions.dailyNotesDescription
        }
        let gist = try await client.gist(id: id)
        guard gist.owner?.id == githubUserID else { throw DraftError.readOnly }
        guard gist.truncated != true else { throw GitHubClientError.incompleteGist }
        if let pendingCreation, gist.files[pendingCreation.filename] != nil {
            let content = try await client.content(gist: gist, filename: pendingCreation.filename)
            if sourceEqual(content, pendingCreation.attemptedContent ?? pendingCreation.text) {
                let recovered = try await coordinator.adoptDailyCreation(
                    id: pendingCreation.id, accountID: accountID, createdGistID: gist.id
                )
                if recovered.filename == target.filename, existing == nil { existing = recovered }
            }
        }
        if gist.files[target.filename] != nil {
            let content = try await client.content(gist: gist, filename: target.filename)
            let draft: DraftSnapshot
            if let existing {
                draft = try await store.refreshCleanDraft(
                    id: existing.id, accountID: accountID, expectedGeneration: existing.generation,
                    content: content, revision: gist.revision
                ).snapshot
            } else {
                draft = try await store.openDraft(
                    accountID: accountID, githubUserID: githubUserID, gistID: id,
                    filename: target.filename, description: gist.description ?? "",
                    content: content, revision: gist.revision
                )
            }
            return TodayNote(target: target, gist: gist, draft: draft)
        }
        let template: String?
        if let file = gist.files[GistConventions.templateFilename] {
            if file.truncated != true, let content = file.content { template = content }
            else { template = try await client.content(gist: gist, filename: GistConventions.templateFilename) }
        } else { template = nil }
        var draft = try await store.newFileDraft(
            accountID: accountID, githubUserID: githubUserID, gistID: id,
            filename: target.filename, description: gist.description ?? "",
            text: GistConventions.dailyContent(template: template, dateFilename: target.filename)
        )
        if publishIfMissing {
            draft = try await coordinator.publish(id: draft.id, accountID: accountID)
            if draft.state == .savedToGitHub {
                let publishedGist = try await client.gist(id: id)
                return TodayNote(target: target, gist: publishedGist, draft: draft)
            }
        }
        return TodayNote(target: target, gist: gist, draft: draft)
    }
}
