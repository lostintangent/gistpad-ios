import Foundation

public struct DailyNoteTarget: Codable, Equatable, Hashable, Sendable {
    public let filename: String
    public let timeZoneIdentifier: String

    public init(date: Date = .now, timeZone: TimeZone = .current) {
        filename = GistConventions.todayFilename(date: date, timeZone: timeZone)
        timeZoneIdentifier = timeZone.identifier
    }
}

public struct TaskProgress: Codable, Equatable, Sendable {
    public let total: Int
    public let completed: Int
    public var remaining: Int { total - completed }

    public init(markdown: String) {
        // Match DailyNotes.tsx exactly, including its lowercase completion marker.
        let source = markdown as NSString
        let tasks = source.ranges(of: #"- \[[ x]\]"#)
        total = tasks.count
        completed = tasks.filter { source.substring(with: $0) == "- [x]" }.count
    }
}

public struct DailyNoteSummary: Equatable, Identifiable, Sendable {
    public var id: String { filename }
    public let filename: String
    public let date: Date?
    public let progress: TaskProgress?
    public let isOverdue: Bool
}

public enum DailyNotesIndex {
    public static func notes(
        gist: Gist, localContent: [String: String] = [:],
        date: Date = .now, timeZone: TimeZone = .current
    ) -> [DailyNoteSummary] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: date)
        let filenames = Set(gist.files.keys).union(localContent.keys)
        return filenames.filter { $0 != GistConventions.templateFilename }.map { filename in
            let day = parseDateFilename(filename, timeZone: timeZone)
            let file = gist.files[filename]
            let content = localContent[filename] ?? (file?.truncated == true ? nil : file?.content)
            let progress = content.map(TaskProgress.init(markdown:))
            return DailyNoteSummary(
                filename: filename, date: day, progress: progress,
                isOverdue: day.map { $0 < today && (progress?.remaining ?? 0) > 0 } ?? false
            )
        }.sorted {
            if $0.isOverdue != $1.isOverdue { return $0.isOverdue }
            if $0.date != $1.date { return ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return $0.filename < $1.filename
        }
    }

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

private extension NSString {
    func ranges(of pattern: String) -> [NSRange] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Invalid built-in task expression")
        }
        return expression.matches(in: self as String, range: NSRange(location: 0, length: length)).map(\.range)
    }
}
