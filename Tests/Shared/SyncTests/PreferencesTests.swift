import Foundation
import Synchronization
import Testing
@testable import Sync

/// The web's Supabase user metadata, read with its defaults and written one field at a time.
struct PreferencesTests {
    @Test func readsTheWebsPreferenceShapesWithDefaults() throws {
        let empty = Preferences(metadata: [:])
        #expect(empty.isAutoSaveEnabled)
        #expect(empty.booleanValue(.isSpellcheckEnabled))
        #expect(!empty.booleanValue(.showDiffs, default: false))
        #expect(empty.accentColor == nil)
        #expect(empty.profileDisplayName == nil)
        #expect(empty.pinnedGists.isEmpty)

        let saved = Preferences(metadata: [
            "isAutoSaveEnabled": .bool(false),
            "accentColor": .string("#facc15"),
            "full_name": .string("  "),
            "name": .string("  Octavia  "),
            "pinnedGists": .array([.string("one")]),
            "tags": .object([
                "ideas": .object(["name": .string("Ideas"), "color": .string("#EBC85A")]),
                "unnamed": .object([:]),
            ]),
            "gistTags": .object(["one": .array([.string("ideas"), .string("unnamed")])]),
        ])
        #expect(!saved.isAutoSaveEnabled)
        #expect(saved.accentColor == "#facc15")
        #expect(saved.profileDisplayName == "Octavia")
        #expect(saved.pinnedGists == ["one"])
        #expect(saved.tagNames(gistID: "one") == ["Ideas"])
        let ideas = try #require(saved.tags.first { $0.id == "ideas" })
        #expect(ideas.name == "Ideas")
        #expect(ideas.colorHex == "#EBC85A")
        let unnamed = try #require(saved.tags.first { $0.id == "unnamed" })
        #expect(unnamed.name == "unnamed")
        #expect(unnamed.colorHex == nil)
    }

    /// A write sends only the fields it changes, keeps everything the web wrote, and survives a relaunch.
    @Test func writesChangeOnlyTheirFieldsKeepTheWebsAndPersist() async throws {
        let server = FixtureServer()
        let accounts = try server.accounts()
        let id = FixtureServer.accountID
        try await server.signIn(accounts)
        server.mergeMetadata([
            "future": ["web-edit": 7], "accentColor": "#facc15", "pinnedGists": ["web-pin"],
            "tags": ["a": ["name": "A", "color": "gold", "future": true], "b": ["name": "B"]],
            "gistTags": ["other": ["a"], "web-pin": ["a", "b"]],
        ])
        let sent = Mutex<[[String]]>([])
        server.intercept { request in
            if request.httpMethod == "PUT" {
                let body = try JSONDecoder().decode(
                    [String: MetadataValue].self, from: FixtureServer.body(of: request))
                sent.withLock { $0.append(body["data"]?.objectValue?.keys.sorted() ?? []) }
            }
            return nil
        }
        let before = server.requests.count

        let updated = try await accounts.update([
            .setPinned(gistID: "native-pin", pinned: true),
            .setTag(gistID: "native-pin", tagID: "a", included: true),
            .setTag(gistID: "other", tagID: "a", included: false),
            .upsertTag(id: "a", name: "Renamed", color: nil),
            .setBoolean(.isAutoSaveEnabled, false),
        ], accountID: id)
        #expect(Array(server.requests.dropFirst(before)) == ["GET /auth/v1/user", "PUT /auth/v1/user"])
        #expect(sent.withLock { $0 } == [["gistTags", "isAutoSaveEnabled", "pinnedGists", "tags"]])
        #expect(updated.preferences.pinnedGists == ["web-pin", "native-pin"])
        #expect(updated.preferences.gistTags == ["web-pin": ["a", "b"], "native-pin": ["a"]])
        #expect(updated.preferences.metadata["tags"]?.objectValue?["a"] == ["name": "Renamed", "future": true])
        #expect(!updated.preferences.isAutoSaveEnabled)
        #expect(updated.preferences.accentColor == "#facc15")
        #expect(updated.preferences.metadata["future"] == ["web-edit": 7])

        let deleted = try await accounts.update([.deleteTag(id: "a"), .setAccentColor("#0ea5E9")], accountID: id)
        #expect(sent.withLock { $0 }.last == ["accentColor", "gistTags", "tags"])
        #expect(deleted.preferences.tags.map(\.id) == ["b"])
        #expect(deleted.preferences.gistTags == ["web-pin": ["b"]])
        #expect(deleted.preferences.accentColor == "#0ea5E9")

        // Refusals never write: an unknown tag, a malformed color, and web metadata in a shape GistPad can't keep.
        await #expect(throws: PreferenceError.unknownTag) {
            try await accounts.update([.setTag(gistID: "one", tagID: "missing", included: true)], accountID: id)
        }
        for invalid in ["", "#123", "#12345678", "yellow", "#+12345"] {
            await #expect(throws: PreferenceError.invalidShape("accentColor")) {
                try await accounts.update([.setAccentColor(invalid)], accountID: id)
            }
        }
        server.mergeMetadata(["pinnedGists": "legacy-value"])
        await #expect(throws: PreferenceError.invalidShape("pinnedGists")) {
            try await accounts.update([.setPinned(gistID: "one", pinned: true)], accountID: id)
        }
        #expect(sent.withLock { $0 }.count == 2)

        server.intercept { request in request.httpMethod == "PUT" ? .init(status: 500) : nil }
        await #expect(throws: (any Error).self) {
            try await accounts.update([.setBoolean(.isAutoSaveEnabled, true)], accountID: id)
        }
        try server.credentials.remove(key: "gistpad-supabase-session")
        #expect(try await server.accounts().connectedAccount() == deleted)
    }
}
