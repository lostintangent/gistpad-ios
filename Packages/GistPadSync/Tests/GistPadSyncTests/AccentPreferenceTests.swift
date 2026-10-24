import Testing
@testable import GistPadSync

struct AccentPreferenceTests {
    @Test("Reading a profile accent never repairs or overwrites stored metadata")
    func reading() {
        for hex in ["#facc15", "#0EA5E9", "invalid"] {
            let preferences = Preferences(metadata: ["accentColor": .string(hex), "future": .integer(7)])
            #expect(preferences.accentColor == hex)
            #expect(!preferences.hasMalformedAccentColor)
            #expect(preferences.metadata["accentColor"] == .string(hex))
            #expect(preferences.metadata["future"] == .integer(7))
        }
        #expect(Preferences(metadata: [:]).accentColor == nil)
        #expect(!Preferences(metadata: [:]).hasMalformedAccentColor)
        #expect(Preferences(metadata: ["accentColor": .bool(true)]).hasMalformedAccentColor)
    }

    @Test("The color control writes only the existing opaque profile field")
    func writing() throws {
        let metadata: [String: MetadataValue] = ["future": .integer(7), "accentColor": .string("#facc15")]
        #expect(try PreferenceOperation.setAccentColor("#0EA5E9").changes(in: metadata) == [
            "accentColor": .string("#0EA5E9")
        ])
        for invalid in ["", "#123", "#12345678", "yellow", "#+12345"] {
            #expect(throws: PreferenceError.invalidShape("accentColor")) {
                try PreferenceOperation.setAccentColor(invalid).changes(in: metadata)
            }
        }
    }
}
