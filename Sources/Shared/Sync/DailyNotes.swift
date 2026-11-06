import Foundation

/// A day's file in the daily notes gist, as the phone knows it: your draft once you've started the day
/// here, otherwise GitHub's cached copy.
public struct DailyNote: Codable, Equatable, Sendable {
    public let day: DailyNote.Day
    /// The daily notes gist, once the phone knows it.
    public let gistID: String?
    /// Your draft of the day, once you've opened it on the phone.
    public let draftID: UUID?
    /// The day's Markdown, or nil when the phone has neither a draft nor a cached copy.
    public let text: String?
    /// Your draft's publish state.
    public let state: PublishState?

    public var date: Date? {
        Self.date(filename: day.filename, timeZone: TimeZone(identifier: day.timeZoneIdentifier) ?? .current)
    }

    public var tasks: [FileTask] { text.map(FileTask.tasks(in:)) ?? [] }
    public var progress: TaskProgress? { text.map(TaskProgress.init(markdown:)) }

    public init(
        day: DailyNote.Day = DailyNote.Day(), gistID: String? = nil, draftID: UUID? = nil,
        text: String? = nil, state: PublishState? = nil
    ) {
        self.day = day
        self.gistID = gistID
        self.draftID = draftID
        self.text = text
        self.state = state
    }

    /// What the library cache and your drafts say about `day`.
    public init(day: DailyNote.Day = DailyNote.Day(), cache: CachedLibrary?, drafts: [Draft]) {
        let gist = cache?.owned.first(where: \.isDailyNote)
        let draft = drafts.first {
            $0.filename == day.filename && ($0.gistID == nil
                ? $0.description == DailyNote.gistDescription : $0.gistID == gist?.id)
        }
        self.init(
            day: day, gistID: gist?.id, draftID: draft?.id,
            text: draft?.text ?? gist.flatMap { cache?.content(gist: $0, filename: day.filename) },
            state: draft?.state)
    }
}

extension DailyNote {
    /// A day in the daily notes gist, named by its `YYYY-MM-DD.md` file in the time zone you were in.
    public struct Day: Codable, Equatable, Hashable, Sendable {
        public let filename: String
        public let timeZoneIdentifier: String

        public init(date: Date = .now, timeZone: TimeZone = .current) {
            filename = DailyNote.filename(date: date, timeZone: timeZone)
            timeZoneIdentifier = timeZone.identifier
        }
    }

    /// The description the web gives the daily notes gist.
    public static let gistDescription = "\u{1F4C6} Daily notes"
    /// The daily notes gist's file that starts each day.
    public static let templateFilename = "template.md"

    /// The day's `YYYY-MM-DD.md` filename in `timeZone`.
    public static func filename(date: Date = .now, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.md", parts.year!, parts.month!, parts.day!)
    }

    /// The day a daily note's `YYYY-MM-DD.md` filename names, in `timeZone`.
    public static func date(filename: String, timeZone: TimeZone = .current) -> Date? {
        filename.hasSuffix(".md") ? FilenameDateFormat.isoDay.date(filename: filename, timeZone: timeZone) : nil
    }

    /// A new day's Markdown: the template with `{{date}}` filled in, or a heading for the day.
    public static func content(template: String?, filename: String) -> String {
        guard let template, !template.isEmpty else { return "# \(GistFile.displayName(filename))\n\n" }
        return GistFile.decodeContent(template).replacingOccurrences(
            of: "{{date}}", with: GistFile.displayName(filename)
        )
    }
}

extension DraftEdit {
    /// Adds `text` to the end of the day's draft: a paragraph, or with `asTask`, one task per line.
    public static func addToToday(_ text: String, asTask: Bool, to draft: Draft) -> Self {
        let source = draft.text
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
            draftID: draft.id, accountID: draft.accountID, expectedGeneration: draft.generation,
            range: NSRange(location: source.utf16.count, length: 0), expectedText: "",
            replacement: separator + content + "\n")
    }
}

public actor DailyNotes {
    private let accountID: UUID
    private let githubUserID: Int64
    private let client: GitHubClient
    private let store: DraftStore
    private let publisher: DraftPublisher

    public init(
        accountID: UUID, githubUserID: Int64,
        client: GitHubClient, store: DraftStore, publisher: DraftPublisher
    ) {
        self.accountID = accountID
        self.githubUserID = githubUserID
        self.client = client
        self.store = store
        self.publisher = publisher
    }

    /// Today's file, ready to edit: your draft once you've started the day, else a draft from the daily
    /// notes gist, else the first day of a new daily notes gist. Autosave publishes it like any other file.
    public func stageToday(target: DailyNote.Day = .init()) async throws -> (gist: Gist?, draft: Draft) {
        let drafts = try await store.drafts(accountID: accountID)
        let cached = try await store.cachedLibrary(accountID: accountID)
        // A day you've started opens from this iPhone, and opening it checks GitHub like any note.
        let day = DailyNote(day: target, cache: cached, drafts: drafts)
        if let started = drafts.first(where: { $0.id == day.draftID }) {
            return (gist: cached?.owned.first { $0.id == started.gistID }, draft: started)
        }
        if let pending = drafts.first(where: {
            $0.gistID == nil && $0.description == DailyNote.gistDescription
        }) {
            // An earlier day never reached GitHub, so it creates the gist that today joins.
            try await publisher.publish(id: pending.id, accountID: accountID)
        }
        guard let gist = try await dailyGist(cached: cached) else {
            return (gist: nil, draft: try await store.newGistDraft(
                accountID: accountID, githubUserID: githubUserID, filename: target.filename,
                description: DailyNote.gistDescription,
                content: DailyNote.content(template: nil, filename: target.filename)))
        }
        guard gist.owner?.id == githubUserID else { throw DraftError.readOnly }
        let content: String
        if let text = try await text(of: target.filename, in: gist) {
            content = text
        } else {
            let template = try await text(of: DailyNote.templateFilename, in: gist)
            content = DailyNote.content(template: template, filename: target.filename)
        }
        let draft = try await store.draft(
            accountID: accountID, githubUserID: githubUserID, gistID: gist.id,
            filename: target.filename, description: gist.description ?? "", content: content,
            revision: gist.revision, isNewFile: gist.files[target.filename] == nil)
        return (gist: gist, draft: draft)
    }

    /// The daily gist as GitHub has it now, because the web may have started today since the
    /// library was cached. Offline, the library on this iPhone decides.
    private func dailyGist(cached: CachedLibrary?) async throws -> Gist? {
        let daily = cached?.owned.first(where: \.isDailyNote)
        do {
            if let daily {
                do { return try await client.gist(id: daily.id) }
                // Deleting its last day on the web deleted it, so look for the one today joins.
                catch GitHubClientError.http(status: 404, _) {}
            }
            return try await client.listGists().first(where: \.isDailyNote)
        } catch let error as URLError where cached != nil && error.code != .cancelled {
            return daily
        }
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
