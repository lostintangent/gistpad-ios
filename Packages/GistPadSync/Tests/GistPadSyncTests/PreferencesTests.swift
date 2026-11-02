import Foundation
import Testing
@testable import GistPadSync

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
        let ideas = try #require(saved.tagDefinitions.first { $0.id == "ideas" })
        #expect(ideas.name == "Ideas")
        #expect(ideas.colorHex == "#EBC85A")
        let unnamed = try #require(saved.tagDefinitions.first { $0.id == "unnamed" })
        #expect(unnamed.name == "unnamed")
        #expect(unnamed.colorHex == nil)
    }

    @Test func operationsChangeOnlyTheirFieldsAndKeepUnknownShapes() throws {
        let metadata: [String: MetadataValue] = [
            "future": .object(["keep": .integer(7)]),
            "accentColor": .string("#facc15"),
            "tags": .object([
                "a": .object(["name": .string("A"), "color": .string("gold"), "future": .bool(true)])
            ]),
            "gistTags": .object(["one": .array([.string("a")]), "other": .array([.string("a")])]),
            "pinnedGists": .array([.string("other")]),
        ]
        let renamed = try PreferenceOperation.upsertTag(id: "a", name: "Renamed", color: nil).changes(in: metadata)
        #expect(Set(renamed.keys) == ["tags"])
        let tag = renamed["tags"]?.objectValue?["a"]?.objectValue
        #expect(tag?["name"] == .string("Renamed"))
        #expect(tag?["color"] == nil)
        #expect(tag?["future"] == .bool(true))

        #expect(try PreferenceOperation.setPinned(gistID: "one", pinned: true).changes(in: metadata)
            == ["pinnedGists": .array([.string("other"), .string("one")])])
        let untagged = try PreferenceOperation.setTag(gistID: "one", tagID: "a", included: false).changes(in: metadata)
        #expect(untagged == ["gistTags": .object(["other": .array([.string("a")])])])
        #expect(throws: PreferenceError.unknownTag) {
            try PreferenceOperation.setTag(gistID: "one", tagID: "missing", included: true).changes(in: metadata)
        }
        let deleted = try PreferenceOperation.deleteTag(id: "a").changes(in: metadata)
        #expect(deleted == ["tags": .object([:]), "gistTags": .object([:])])

        #expect(try PreferenceOperation.setAccentColor("#0EA5E9").changes(in: metadata)
            == ["accentColor": .string("#0EA5E9")])
        for invalid in ["", "#123", "#12345678", "yellow", "#+12345"] {
            #expect(throws: PreferenceError.invalidShape("accentColor")) {
                try PreferenceOperation.setAccentColor(invalid).changes(in: metadata)
            }
        }
        #expect(throws: PreferenceError.invalidShape("pinnedGists")) {
            try PreferenceOperation.setPinned(gistID: "one", pinned: true)
                .changes(in: ["pinnedGists": .string("legacy-value")])
        }

        let updated = try Preferences(metadata: metadata).applying(.setBoolean(.isAutoSaveEnabled, false))
        #expect(!updated.isAutoSaveEnabled)
        #expect(updated.metadata["future"] == metadata["future"])
        #expect(updated.accentColor == "#facc15")
    }
}
