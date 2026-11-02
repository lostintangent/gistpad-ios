import Foundation
import GistPadSync

public enum NotebookPlatformError: LocalizedError, Equatable, Sendable {
    case accountChanged
    case staleTask
    case editingInProgress
    case emptyText

    public var errorDescription: String? {
        switch self {
        case .accountChanged:
            String(localized: "Open GistPad and sign in to the notebook used by this action.")
        case .staleTask:
            String(localized: "The note changed. Refresh the widget before changing this task.")
        case .editingInProgress:
            String(localized: "Finish the current edit in GistPad before changing this task.")
        case .emptyText:
            String(localized: "Enter some text to add to Today.")
        }
    }
}

public struct TodayTask: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(draftID.uuidString)/\(generation)/\(markerLocation)" }
    let draftID: UUID
    let generation: UInt64
    let markerLocation: Int
    public let title: String
    public let isCompleted: Bool

    public func command(accountID: UUID, completed: Bool) -> SharedDraftCommand {
        SharedDraftCommand(
            accountID: accountID, draftID: draftID, expectedGeneration: generation,
            edit: DraftSourceEdit(
                location: markerLocation, length: 1,
                expectedText: isCompleted ? "x" : " ", replacement: completed ? "x" : " "))
    }
}

public struct SystemToday: Codable, Equatable, Sendable {
    public let filename: String
    public let timeZoneIdentifier: String
    let excerpt: String?
    public let tasks: [TodayTask]
    let route: NotebookRoute
    let isAvailable: Bool
    let needsAttention: Bool
}

public struct NotebookSystemSnapshot: Codable, Equatable, Sendable {
    public let accountID: UUID?
    let accentHex: String?
    let gists: [GistEntity]
    public let today: SystemToday

    public static func make(
        accountID: UUID?, cache: CachedLibrarySnapshot?, drafts: [DraftSnapshot],
        date: Date = .now, timeZone: TimeZone = .current
    ) -> Self {
        let target = DailyNoteTarget(date: date, timeZone: timeZone)
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
        let daily = cache?.owned.first(where: \.isDailyNote)
        let draft = drafts.first { candidate in
            candidate.filename == target.filename && (
                daily == nil
                    ? candidate.gistID == nil
                        && candidate.description == GistConventions.dailyNotesDescription
                    : candidate.gistID == daily?.id)
        }
        let text = draft?.text ?? daily.flatMap { cache?.content(gist: $0, filename: target.filename) }
        let route: NotebookRoute
        if let daily, daily.files[target.filename] != nil || draft != nil {
            route = .note(gistID: daily.id, filename: target.filename)
        } else if let draft, let accountID {
            route = .draft(accountID: accountID, draftID: draft.id)
        } else {
            route = .today
        }
        let needsAttention = switch draft?.state {
        case .reconnect, .failed, .conflict: true
        default: false
        }
        return Self(
            accountID: accountID,
            accentHex: cache?.preferences.accentColor,
            gists: gists.sorted {
                $0.updatedAt == $1.updatedAt
                    ? $0.id < $1.id : ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            },
            today: SystemToday(
                filename: target.filename, timeZoneIdentifier: target.timeZoneIdentifier,
                excerpt: excerpt(text), tasks: draft.map { tasks(in: $0) } ?? [],
                route: route, isAvailable: text != nil, needsAttention: needsAttention))
    }

    public static func preview(date: Date = .now) -> Self {
        let accountID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let draftID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let target = DailyNoteTarget(date: date)
        return Self(
            accountID: accountID, accentHex: nil, gists: [],
            today: SystemToday(
                filename: target.filename, timeZoneIdentifier: target.timeZoneIdentifier,
                excerpt: "A little room for what matters today.",
                tasks: [
                    TodayTask(
                        draftID: draftID, generation: 0, markerLocation: 3,
                        title: "Make room for a good idea", isCompleted: false),
                    TodayTask(
                        draftID: draftID, generation: 0, markerLocation: 37,
                        title: "Take the long way home", isCompleted: true)
                ],
                route: .today, isAvailable: true, needsAttention: false))
    }

    private static func excerpt(_ source: String?) -> String? {
        guard let source else { return nil }
        let text = source.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("- [") }
            .joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(160))
    }

    private static func tasks(in draft: DraftSnapshot) -> [TodayTask] {
        let source = draft.text as NSString
        var fence: (Character, Int)?
        var result: [TodayTask] = []
        source.enumerateSubstrings(
            in: NSRange(location: 0, length: source.length), options: .byLines
        ) { line, range, _, _ in
            guard let value = line else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let first = trimmed.first
            if first == "`" || first == "~" {
                let count = trimmed.prefix(while: { $0 == first }).count
                if count >= 3, let marker = first {
                    if let current = fence {
                        if marker == current.0, count >= current.1,
                           trimmed.dropFirst(count).allSatisfy(\.isWhitespace) {
                            fence = nil
                        }
                    } else { fence = (marker, count) }
                    return
                }
            }
            if fence == nil, trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") {
                let prefixLength = String(value.prefix(while: \.isWhitespace)).utf16.count
                let markerLocation = range.location + prefixLength + 3
                if markerLocation < source.length {
                    result.append(TodayTask(
                        draftID: draft.id, generation: draft.generation,
                        markerLocation: markerLocation,
                        title: String(trimmed.dropFirst(6)),
                        isCompleted: trimmed.hasPrefix("- [x]")))
                }
            }
        }
        return result
    }
}
