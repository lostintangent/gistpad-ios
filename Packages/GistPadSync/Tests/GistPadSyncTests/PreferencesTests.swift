import Foundation
import Testing
@testable import GistPadSync

struct PreferencesTests {
    @Test func typedValuesPreserveDefaultsAndStoredValues() {
        let empty = Preferences(metadata: [:])
        #expect(empty.booleanValue(.isSpellcheckEnabled))
        #expect(!empty.booleanValue(.showDiffs, default: false))
        #expect(empty.profileDisplayName == nil)
        let saved = Preferences(metadata: [
            "isSpellcheckEnabled": .bool(false),
            "full_name": .string("  "),
            "name": .string("  Octavia  "),
            "other": .string("kept"),
        ])
        #expect(!saved.booleanValue(.isSpellcheckEnabled))
        #expect(saved.profileDisplayName == "Octavia")
    }

    @Test func typedTagDefinitionsRetainIDsNamesAndOptionalColors() throws {
        let saved = Preferences(metadata: [
            "tags": .object([
                "ideas": .object(["name": .string("Ideas"), "color": .string("#EBC85A")]),
                "unnamed": .object([:]),
            ])
        ])
        let ideas = try #require(saved.tagDefinitions.first { $0.id == "ideas" })
        #expect(ideas.name == "Ideas")
        #expect(ideas.colorHex == "#EBC85A")
        let unnamed = try #require(saved.tagDefinitions.first { $0.id == "unnamed" })
        #expect(unnamed.name == "unnamed")
        #expect(unnamed.colorHex == nil)
    }

    @Test func typedFixtureUpdatesUseExistingValidationAndRetainUnchangedMetadata() throws {
        let original = Preferences(metadata: ["other": .string("kept")])
        let updated = try original.applying(.setBoolean(.isAutoSaveEnabled, false))
            .applying(.setAccentColor("#EAB308"))
        #expect(!updated.isAutoSaveEnabled)
        #expect(updated.accentColor == "#EAB308")
        #expect(updated.metadata["other"] == .string("kept"))
        #expect(original.accentColor == nil)
        #expect(throws: PreferenceError.invalidShape("accentColor")) {
            try original.applying(.setAccentColor("invalid"))
        }
        let fixture = Preferences(isAutoSaveEnabled: true, accentColor: "#EAB308")
        #expect(fixture.isAutoSaveEnabled)
        #expect(fixture.accentColor == "#EAB308")
        #expect(Preferences(isAutoSaveEnabled: false, accentColor: nil).accentColor == nil)
    }
}
