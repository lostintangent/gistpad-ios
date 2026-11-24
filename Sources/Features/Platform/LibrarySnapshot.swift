import Foundation
import Store

/// What widgets, Shortcuts and Spotlight know about the library, shared through the app group.
public struct LibrarySnapshot: Codable, Sendable {
    public let accountID: UUID?
    let accentHex: String?
    public let gists: [GistEntity]
    /// The widget's recent gists: your own, newest edit anywhere in the gist first, without daily
    /// notes or archived gists.
    let recents: [GistEntity]

    public static func make(
        account: GistPadAccount?, cache: GistCache?, drafts: [GistFileDraft],
        visibleText: (String) -> String = { $0 }
    ) -> Self {
        guard let account else { return Self(accountID: nil, accentHex: nil, gists: [], recents: []) }
        let preferences = account.preferences
        func note(
            _ title: String, text: String?, updatedAt: Date, link: GistPadLink, in gist: Gist?
        ) -> GistEntity {
            GistEntity(
                title: title, excerpt: excerpt(text.map(visibleText)),
                tags: gist.map { preferences.tagNames(gistID: $0.id) } ?? [],
                updatedAt: updatedAt, link: link, accountID: account.id,
                folderName: gist?.displayName,
                pinned: gist.map { preferences.pinnedGists.contains($0.id) } ?? false)
        }
        var gists: [GistEntity] = []
        var recents: [GistEntity] = []
        let owned = Set(cache?.owned.map(\.id) ?? [])
        for gist in cache?.gists ?? [] {
            let filenames = gist.markdownFilenames
            let defaultFilename = gist.defaultMarkdownFilename
            let gistDrafts = drafts.filter { $0.gistID == gist.id && $0.filename.hasSuffix(".md") }
            let files = filenames.map { filename in
                let draft = gistDrafts.first { $0.filename == filename }
                // A draft is typing GitHub doesn't have yet, so it's newer.
                return note(
                    filename == defaultFilename ? gist.displayName : Gist.File.displayName(filename),
                    text: draft?.text ?? cache?.version(of: filename, gistID: gist.id)?.text,
                    updatedAt: max(gist.updatedAt, draft?.editedAt ?? gist.updatedAt),
                    link: .gist(id: gist.id, filename: filename), in: gist)
            } + gistDrafts.filter { !filenames.contains($0.filename) }.map { draft in
                note(
                    Gist.File.displayName(draft.filename), text: draft.text, updatedAt: draft.editedAt,
                    link: .gist(id: gist.id, filename: draft.filename), in: gist)
            }
            gists += files
            // The widget shows the gist by its default file, as of the newest edit to any of its files.
            if owned.contains(gist.id), !gist.isDailyNote, !gist.isArchived,
                var recent = files.first(where: { $0.link == .gist(id: gist.id, filename: defaultFilename) })
            {
                recent.updatedAt = files.map(\.updatedAt).max() ?? recent.updatedAt
                recents.append(recent)
            }
        }
        for draft in drafts where draft.gistID == nil {
            let unpublished = note(
                draft.newGistName ?? String(localized: "Untitled"), text: draft.text,
                updatedAt: draft.editedAt,
                link: .unpublishedGist(accountID: account.id, draftID: draft.id), in: nil)
            gists.append(unpublished)
            if draft.newGistName != DailyNote.gistDescription { recents.append(unpublished) }
        }
        return Self(
            accountID: account.id,
            accentHex: preferences.accentColor,
            gists: gists.sorted(by: newestFirst),
            recents: Array(recents.sorted(by: newestFirst).prefix(3)))
    }

    private static func newestFirst(_ a: GistEntity, _ b: GistEntity) -> Bool {
        a.updatedAt == b.updatedAt ? a.id < b.id : a.updatedAt > b.updatedAt
    }

    public static func preview() -> Self {
        let recents = [
            ("Thanksgiving menu", -1.5), ("Widget ideas", -3.0), ("Reading list", -26.0)
        ].enumerated().map { index, gist in
            GistEntity(
                title: gist.0, tags: [], updatedAt: Date.now.addingTimeInterval(gist.1 * 3600),
                link: .gist(id: "preview\(index)", filename: nil), accountID: nil)
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

    /// The snapshot an intent or query can trust: its account is still the one signed in to the app.
    static func read(validating app: any PlatformActions) async throws -> Self? {
        let snapshot = try read()
        if let accountID = snapshot?.accountID {
            try await app.validateAccount(accountID)
        }
        return snapshot
    }

    /// Written atomically, readable after first unlock so Lock Screen and StandBy can show it.
    public func write() throws {
        let url = try Self.fileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func fileURL() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.dev.gistpad.GistPad")
        else { throw CocoaError(.fileNoSuchFile) }
        return container.appending(path: "Library/Application Support/GistPad/library.snapshot")
    }
}
