import Foundation
import Sync

public enum PlatformError: LocalizedError, Equatable, Sendable {
    case accountChanged
    case editingInProgress
    case emptyNoteText
    case emptyNoteName
    case unsupportedNoteCreation
    case unsupportedNoteUpdate

    public var errorDescription: String? {
        switch self {
        case .accountChanged:
            String(localized: "Open GistPad and sign in to the account this action uses.")
        case .editingInProgress:
            String(localized: "Finish the current edit in GistPad, then try again.")
        case .emptyNoteText:
            String(localized: "Say or type something to add to this note.")
        case .emptyNoteName:
            String(localized: "Give the new note a name.")
        case .unsupportedNoteCreation:
            String(localized: "Siri can't create a pinned note, add attachments, or put it in an existing gist.")
        case .unsupportedNoteUpdate:
            String(localized: "Siri can't make that change to this gist. Open it in GistPad instead.")
        }
    }
}

/// What widgets, Shortcuts and Spotlight know about the library, shared through the app group.
public struct LibrarySnapshot: Codable, Equatable, Sendable {
    public let accountID: UUID?
    let accentHex: String?
    public let gists: [GistEntity]
    /// The widget's recent gists: your own, newest edit first, without daily notes or archived gists.
    let recents: [GistEntity]

    public static func make(
        accountID: UUID?, cache: CachedLibrary?, drafts: [Draft],
        visibleText: (String) -> String = { $0 }
    ) -> Self {
        var gists: [(entity: GistEntity, isRecent: Bool)] = []
        if let accountID {
            let owned = Set(cache?.owned.map(\.id) ?? [])
            for gist in cache?.gists ?? [] {
                for filename in gist.markdownFilenames {
                    let isDefault = filename == gist.defaultMarkdownFilename
                    let draft = drafts.first { $0.gistID == gist.id && $0.filename == filename }
                    let text = draft?.text ?? cache?.content(gist: gist, filename: filename)
                    let body = text.map(visibleText)
                    // Opening a gist starts its draft, so only typing that GitHub doesn't have yet is newer.
                    let editedAt = draft?.hasUnpublishedEdits == true ? draft?.updatedAt : nil
                    gists.append((
                        GistEntity(
                            title: isDefault ? gist.displayName : GistFile.displayName(filename),
                            excerpt: excerpt(body),
                            tags: cache?.preferences.tagNames(gistID: gist.id) ?? [],
                            updatedAt: max(gist.updatedAt, editedAt ?? gist.updatedAt),
                            link: .gist(id: gist.id, filename: isDefault ? nil : filename),
                            accountID: accountID, folderName: gist.displayName,
                            body: nil,
                            pinned: cache?.preferences.pinnedGists.contains(gist.id) ?? false),
                        isDefault && owned.contains(gist.id) && !gist.isDailyNote && !gist.isArchived))
                }
            }
            for draft in drafts {
                guard let gistID = draft.gistID, draft.filename.hasSuffix(".md"),
                      let gist = cache?.gists.first(where: { $0.id == gistID }),
                      !gist.markdownFilenames.contains(draft.filename)
                else { continue }
                let body = visibleText(draft.text)
                gists.append((
                    GistEntity(
                        title: GistFile.displayName(draft.filename),
                        excerpt: excerpt(body),
                        tags: cache?.preferences.tagNames(gistID: gistID) ?? [],
                        updatedAt: draft.updatedAt,
                        link: .gist(id: gistID, filename: draft.filename),
                        accountID: accountID, folderName: gist.displayName,
                        body: nil,
                        pinned: cache?.preferences.pinnedGists.contains(gistID) ?? false),
                    false))
            }
            for draft in drafts where draft.gistID == nil {
                let text = draft.text
                let body = visibleText(text)
                gists.append((
                    GistEntity(
                        title: draft.description.isEmpty ? String(localized: "Untitled") : draft.description,
                        excerpt: excerpt(body), tags: [], updatedAt: draft.updatedAt,
                        link: .unpublishedGist(accountID: accountID, draftID: draft.id),
                        accountID: accountID, folderName: nil,
                        body: nil, pinned: false),
                    draft.description != DailyNote.gistDescription))
            }
        }
        gists.sort {
            $0.entity.updatedAt == $1.entity.updatedAt
                ? $0.entity.id < $1.entity.id
                : ($0.entity.updatedAt ?? .distantPast) > ($1.entity.updatedAt ?? .distantPast)
        }
        return Self(
            accountID: accountID,
            accentHex: cache?.preferences.accentColor,
            gists: gists.map(\.entity),
            recents: Array(gists.filter(\.isRecent).prefix(3).map(\.entity)))
    }

    public static func preview(date: Date = .now) -> Self {
        let recents = [
            ("Thanksgiving menu", -1.5), ("Widget ideas", -3.0), ("Reading list", -26.0)
        ].enumerated().map { index, gist in
            GistEntity(
                title: gist.0, excerpt: nil, tags: [], updatedAt: date.addingTimeInterval(gist.1 * 3600),
                link: .gist(id: "preview\(index)", filename: nil),
                accountID: nil, folderName: nil, body: nil, pinned: nil)
        }
        return Self(accountID: UUID(), accentHex: nil, gists: recents, recents: recents)
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
