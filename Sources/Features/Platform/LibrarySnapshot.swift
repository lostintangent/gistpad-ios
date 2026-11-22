import Foundation
import Store

/// What widgets, Shortcuts and Spotlight know about the library, shared through the app group.
public struct LibrarySnapshot: Codable, Sendable {
    public let accountID: UUID?
    let accentHex: String?
    public let gists: [GistEntity]
    /// The widget's recent gists: your own, newest edit first, without daily notes or archived gists.
    let recents: [GistEntity]

    public static func make(
        account: GistPadAccount?, cache: GistCache?, drafts: [GistFileDraft],
        visibleText: (String) -> String = { $0 }
    ) -> Self {
        guard let account else { return Self(accountID: nil, accentHex: nil, gists: [], recents: []) }
        let preferences = account.preferences
        var gists: [(entity: GistEntity, isRecent: Bool)] = []
        func add(
            _ title: String, text: String?, updatedAt: Date, link: GistPadLink, in gist: Gist?,
            isRecent: Bool
        ) {
            gists.append((
                GistEntity(
                    title: title, excerpt: excerpt(text.map(visibleText)),
                    tags: gist.map { preferences.tagNames(gistID: $0.id) } ?? [],
                    updatedAt: updatedAt, link: link, accountID: account.id,
                    folderName: gist?.displayName,
                    pinned: gist.map { preferences.pinnedGists.contains($0.id) } ?? false),
                isRecent))
        }
        let owned = Set(cache?.owned.map(\.id) ?? [])
        for gist in cache?.gists ?? [] {
            for filename in gist.markdownFilenames {
                let isDefault = filename == gist.defaultMarkdownFilename
                let draft = drafts.first { $0.gistID == gist.id && $0.filename == filename }
                // A draft is typing GitHub doesn't have yet, so it's newer.
                add(
                    isDefault ? gist.displayName : Gist.File.displayName(filename),
                    text: draft?.text ?? cache?.version(of: filename, gistID: gist.id)?.text,
                    updatedAt: max(gist.updatedAt, draft?.editedAt ?? gist.updatedAt),
                    link: .gist(id: gist.id, filename: isDefault ? nil : filename), in: gist,
                    isRecent: isDefault && owned.contains(gist.id) && !gist.isDailyNote && !gist.isArchived)
            }
        }
        for draft in drafts {
            if let gistID = draft.gistID {
                guard draft.filename.hasSuffix(".md"),
                      let gist = cache?.gists.first(where: { $0.id == gistID }),
                      !gist.markdownFilenames.contains(draft.filename)
                else { continue }
                add(
                    Gist.File.displayName(draft.filename), text: draft.text, updatedAt: draft.editedAt,
                    link: .gist(id: gistID, filename: draft.filename), in: gist, isRecent: false)
            }
        }
        for draft in drafts where draft.gistID == nil {
            add(
                draft.newGistName ?? String(localized: "Untitled"), text: draft.text,
                updatedAt: draft.editedAt,
                link: .unpublishedGist(accountID: account.id, draftID: draft.id), in: nil,
                isRecent: draft.newGistName != DailyNote.gistDescription)
        }
        gists.sort {
            $0.entity.updatedAt == $1.entity.updatedAt
                ? $0.entity.id < $1.entity.id
                : ($0.entity.updatedAt ?? .distantPast) > ($1.entity.updatedAt ?? .distantPast)
        }
        return Self(
            accountID: account.id,
            accentHex: preferences.accentColor,
            gists: gists.map(\.entity),
            recents: Array(gists.filter(\.isRecent).prefix(3).map(\.entity)))
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
