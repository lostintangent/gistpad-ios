import Foundation
import GistPadSync

public enum PlatformError: LocalizedError, Equatable, Sendable {
    case accountChanged
    case staleTask
    case editingInProgress

    public var errorDescription: String? {
        switch self {
        case .accountChanged:
            String(localized: "Open GistPad and sign in to the account this action uses.")
        case .staleTask:
            String(localized: "Today's note changed. Refresh the widget to change this task.")
        case .editingInProgress:
            String(localized: "Finish the current edit in GistPad before changing this task.")
        }
    }
}

/// What widgets, Shortcuts and Spotlight know about the library, shared through the app group.
public struct LibrarySnapshot: Codable, Equatable, Sendable {
    public let accountID: UUID?
    let accentHex: String?
    let gists: [GistEntity]
    public let today: DailyNote

    public static func make(
        accountID: UUID?, cache: CachedLibrary?, drafts: [Draft],
        date: Date = .now, timeZone: TimeZone = .current
    ) -> Self {
        var gists: [GistEntity] = []
        if let accountID {
            for gist in cache?.gists ?? [] {
                guard let filename = gist.defaultMarkdownFilename else { continue }
                let draft = drafts.first { $0.gistID == gist.id && $0.filename == filename }
                gists.append(GistEntity(
                    title: gist.displayName,
                    excerpt: excerpt(draft?.text ?? cache?.content(gist: gist, filename: filename)),
                    tags: cache?.preferences.tagNames(gistID: gist.id) ?? [],
                    updatedAt: gist.updatedAt, link: .gist(id: gist.id, filename: nil)))
            }
            for draft in drafts where draft.gistID == nil {
                gists.append(GistEntity(
                    title: draft.description.isEmpty ? String(localized: "Untitled") : draft.description,
                    excerpt: excerpt(draft.text), tags: [], updatedAt: nil,
                    link: .unpublishedGist(accountID: accountID, draftID: draft.id)))
            }
        }
        return Self(
            accountID: accountID,
            accentHex: cache?.preferences.accentColor,
            gists: gists.sorted {
                $0.updatedAt == $1.updatedAt
                    ? $0.id < $1.id : ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            },
            today: DailyNote(day: DailyNote.Day(date: date, timeZone: timeZone), cache: cache, drafts: drafts))
    }

    public static func preview(date: Date = .now) -> Self {
        Self(
            accountID: UUID(), accentHex: nil, gists: [],
            today: DailyNote(
                day: DailyNote.Day(date: date),
                text: "- [ ] Make room for a good idea\n- [x] Take the long way home\n"))
    }

    static func excerpt(_ source: String?) -> String? {
        guard let source else { return nil }
        let text = source.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("- [") }
            .joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(160))
    }
}

extension LibrarySnapshot {
    public static func read() throws -> Self? {
        let url = try fileURL()
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    /// Written atomically, readable after first unlock so Lock Screen and StandBy can show it.
    public func write() throws {
        let url = try Self.fileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func fileURL() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.dev.gistpad.GistPad")
        else { throw CocoaError(.fileNoSuchFile) }
        // The file keeps its first name, so an update never leaves the old one behind.
        return container
            .appendingPathComponent("Library/Application Support/GistPad", isDirectory: true)
            .appendingPathComponent("notebook.snapshot")
    }
}
