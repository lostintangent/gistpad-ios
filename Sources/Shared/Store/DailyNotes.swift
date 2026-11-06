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
    public init(day: DailyNote.Day = DailyNote.Day(), cache: GistCache?, drafts: [Draft]) {
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
        guard let template, !template.isEmpty else { return "# \(Gist.File.displayName(filename))\n\n" }
        return Gist.File.decodeContent(template).replacingOccurrences(
            of: "{{date}}", with: Gist.File.displayName(filename)
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
        return Self(draft: draft, text: separator + content + "\n")
    }
}
