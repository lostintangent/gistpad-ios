import Foundation
import GistPadSync

public enum NotebookPlatformError: LocalizedError, Equatable, Sendable {
    case accountChanged
    case staleTask
    case editingInProgress

    public var errorDescription: String? {
        switch self {
        case .accountChanged:
            String(localized: "Open GistPad and sign in to the notebook used by this action.")
        case .staleTask:
            String(localized: "The note changed. Refresh the widget before changing this task.")
        case .editingInProgress:
            String(localized: "Finish the current edit in GistPad before changing this task.")
        }
    }
}

public struct NotebookSystemSnapshot: Codable, Equatable, Sendable {
    public let accountID: UUID?
    let accentHex: String?
    let gists: [GistEntity]
    public let today: DailyNote

    public static func make(
        accountID: UUID?, cache: CachedLibrarySnapshot?, drafts: [DraftSnapshot],
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
                    updatedAt: gist.updatedAt, route: .note(gistID: gist.id, filename: nil)))
            }
            for draft in drafts where draft.gistID == nil {
                gists.append(GistEntity(
                    title: draft.description.isEmpty ? String(localized: "Untitled") : draft.description,
                    excerpt: excerpt(draft.text), tags: [], updatedAt: nil,
                    route: .draft(accountID: accountID, draftID: draft.id)))
            }
        }
        return Self(
            accountID: accountID,
            accentHex: cache?.preferences.accentColor,
            gists: gists.sorted {
                $0.updatedAt == $1.updatedAt
                    ? $0.id < $1.id : ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            },
            today: DailyNote(day: DailyNoteTarget(date: date, timeZone: timeZone), cache: cache, drafts: drafts))
    }

    public static func preview(date: Date = .now) -> Self {
        Self(
            accountID: UUID(), accentHex: nil, gists: [],
            today: DailyNote(
                day: DailyNoteTarget(date: date),
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
