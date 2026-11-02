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

extension DraftSourceEdit {
    /// Adds `text` to the end of the day's `source`: a paragraph, or with `asTask`, one task per line.
    public static func addToToday(_ text: String, asTask: Bool, in source: String) -> Self {
        let content = asTask
            ? text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { "- [ ] " + $0 }
                .joined(separator: "\n")
            : text.trimmingCharacters(in: .newlines)
        let separator = source.isEmpty || source.hasSuffix(asTask ? "\n" : "\n\n") ? ""
            : asTask || source.hasSuffix("\n") ? "\n" : "\n\n"
        return Self(
            location: source.utf16.count, length: 0, expectedText: "", replacement: separator + content + "\n")
    }
}

public enum DailyNotesIndex {
    /// The day a daily note's `YYYY-MM-DD.md` filename names, in `timeZone`.
    public static func parseDateFilename(_ filename: String, timeZone: TimeZone = .current) -> Date? {
        filename.hasSuffix(".md") ? FilenameDateFormat.isoDay.date(filename: filename, timeZone: timeZone) : nil
    }
}

public struct TodayNote: Equatable, Sendable {
    public let gist: Gist?
    public let draft: DraftSnapshot

    public init(gist: Gist?, draft: DraftSnapshot) {
        self.gist = gist
        self.draft = draft
    }
}

public actor DailyNotesService {
    private let accountID: UUID
    private let githubUserID: Int64
    private let client: GitHubClient
    private let store: DraftStore
    private let coordinator: SyncCoordinator

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

    /// Today's file, ready to edit: your draft once you've started the day, else a draft from the daily
    /// notes gist, else the first day of a new daily notes gist. Autosave publishes it like any other file.
    public func stageToday(target: DailyNoteTarget = DailyNoteTarget()) async throws -> TodayNote {
        let drafts = try await store.drafts(accountID: accountID)
        if let pending = drafts.first(where: {
            $0.gistID == nil && $0.description == GistConventions.dailyNotesDescription
        }) {
            if pending.filename == target.filename { return TodayNote(gist: nil, draft: pending) }
            // An earlier day never reached GitHub, so it creates the gist that today joins.
            try await coordinator.publish(id: pending.id, accountID: accountID)
        }
        guard let gist = try await dailyGist() else {
            return TodayNote(gist: nil, draft: try await store.createGistDraft(
                accountID: accountID, githubUserID: githubUserID, filename: target.filename,
                description: GistConventions.dailyNotesDescription,
                content: GistConventions.dailyContent(template: nil, dateFilename: target.filename)))
        }
        guard gist.owner?.id == githubUserID else { throw DraftError.readOnly }
        if let existing = try await store.drafts(accountID: accountID).first(where: {
            $0.gistID == gist.id && $0.filename == target.filename
        }) {
            return TodayNote(gist: gist, draft: existing)
        }
        let content: String
        if let text = try await text(of: target.filename, in: gist) {
            content = text
        } else {
            let template = try await text(of: GistConventions.templateFilename, in: gist)
            content = GistConventions.dailyContent(template: template, dateFilename: target.filename)
        }
        let draft = try await store.openDraft(
            accountID: accountID, githubUserID: githubUserID, gistID: gist.id,
            filename: target.filename, description: gist.description ?? "", content: content,
            revision: gist.revision, isNewFile: gist.files[target.filename] == nil)
        return TodayNote(gist: gist, draft: draft)
    }

    private func dailyGist() async throws -> Gist? {
        if let cached = try await store.cachedLibrary(accountID: accountID)?.owned.first(where: \.isDailyNote) {
            return cached
        }
        return try await client.listGists().first(where: \.isDailyNote)
    }

    /// A file's text from the cache when it's current, otherwise from GitHub, which then caches it.
    private func text(of filename: String, in gist: Gist) async throws -> String? {
        guard gist.files[filename] != nil else { return nil }
        if let cached = try await store.cachedLibrary(accountID: accountID)?
            .cachedContent(gist: gist, filename: filename), cached.isCurrent {
            return cached.text
        }
        let text = try await client.content(gist: gist, filename: filename)
        try await store.cacheContent(text, gist: gist, filename: filename, accountID: accountID)
        return text
    }
}
