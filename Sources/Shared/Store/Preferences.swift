import Auth
import Foundation

/// A tag you give gists, with its name and color, as GistPad keeps it in your preferences.
public struct Tag: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let colorHex: String?

    public init(id: String, name: String, colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}

public struct GistPadPreferences: Codable, Equatable, Sendable {
    public let metadata: [String: AnyJSON]

    public init(metadata: [String: AnyJSON]) { self.metadata = metadata }

    public func booleanValue(_ preference: BooleanPreference, default fallback: Bool = true) -> Bool {
        metadata[preference.rawValue]?.boolValue ?? fallback
    }

    public var tags: [Tag] {
        tagMetadata.map { id, value in
            Tag(
                id: id, name: value.objectValue?["name"]?.stringValue ?? id,
                colorHex: value.objectValue?["color"]?.stringValue)
        }
    }

    public var accentColor: String? { metadata["accentColor"]?.stringValue }
    public var pinnedGists: [String] {
        metadata["pinnedGists"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
    private var tagMetadata: [String: AnyJSON] { metadata["tags"]?.objectValue ?? [:] }
    public var gistTags: [String: [String]] {
        (metadata["gistTags"]?.objectValue ?? [:]).mapValues {
            $0.arrayValue?.compactMap(\.stringValue) ?? []
        }
    }

    public func tagNames(gistID: String) -> [String] {
        (gistTags[gistID] ?? []).compactMap { tagMetadata[$0]?.objectValue?["name"]?.stringValue }
    }
}

public enum PreferenceError: Error, Equatable, Sendable {
    case invalidShape(String)
    case invalidIdentifier
    case unknownTag
}

extension PreferenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownTag: String(localized: "This tag no longer exists.")
        case .invalidShape: String(localized: "GistPad can’t safely make this change. Make it on gistpad.dev.")
        case .invalidIdentifier: String(localized: "This change couldn’t be saved. Try again.")
        }
    }
}

public enum BooleanPreference: String, Sendable {
    case isAutoSaveEnabled, isSpellcheckEnabled, showFrontmatter, showInlineComments
}

extension GistPadPreferences {
    /// One edit to the account metadata the web shares, like a pin, a tag or a preference.
    public enum Change: Equatable, Sendable {
        case setBoolean(BooleanPreference, Bool)
        case setAccentColor(String)
        case setPinned(gistID: String, pinned: Bool)
        case upsertTag(id: String, name: String, color: String?)
        case deleteTag(id: String)
        case setTag(gistID: String, tagID: String, included: Bool)

        public func changes(in metadata: [String: AnyJSON]) throws -> [String: AnyJSON] {
            switch self {
            case .setBoolean(let preference, let value):
                return [preference.rawValue: .bool(value)]
            case .setAccentColor(let hex):
                guard hex.first == "#", hex.utf8.count == 7,
                      hex.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit })
                else { throw PreferenceError.invalidShape("accentColor") }
                return ["accentColor": .string(hex)]
            case .setPinned(let gistID, let pinned):
                try requireID(gistID)
                var pins = try strings(metadata["pinnedGists"], key: "pinnedGists")
                if pinned, !pins.contains(gistID) { pins.append(gistID) }
                if !pinned { pins.removeAll { $0 == gistID } }
                return ["pinnedGists": .array(pins.map(AnyJSON.string))]
            case .upsertTag(let id, let name, let color):
                try requireID(id)
                var tags = try object(metadata["tags"], key: "tags")
                var tag = try object(tags[id], key: "tags.\(id)")
                tag["name"] = .string(name)
                tag["color"] = color.map(AnyJSON.string)
                tags[id] = .object(tag)
                return ["tags": .object(tags)]
            case .deleteTag(let id):
                try requireID(id)
                var tags = try object(metadata["tags"], key: "tags")
                var gistTags = try object(metadata["gistTags"], key: "gistTags")
                tags.removeValue(forKey: id)
                for (gist, value) in gistTags {
                    let ids = try strings(value, key: "gistTags.\(gist)").filter { $0 != id }
                    if ids.isEmpty { gistTags.removeValue(forKey: gist) }
                    else { gistTags[gist] = .array(ids.map(AnyJSON.string)) }
                }
                return ["tags": .object(tags), "gistTags": .object(gistTags)]
            case .setTag(let gistID, let tagID, let included):
                try requireID(gistID)
                try requireID(tagID)
                let tags = try object(metadata["tags"], key: "tags")
                guard !included || tags[tagID] != nil else { throw PreferenceError.unknownTag }
                var gistTags = try object(metadata["gistTags"], key: "gistTags")
                var ids = try strings(gistTags[gistID], key: "gistTags.\(gistID)")
                if included, !ids.contains(tagID) { ids.append(tagID) }
                if !included { ids.removeAll { $0 == tagID } }
                if ids.isEmpty { gistTags.removeValue(forKey: gistID) }
                else { gistTags[gistID] = .array(ids.map(AnyJSON.string)) }
                return ["gistTags": .object(gistTags)]
            }
        }

        private func requireID(_ value: String) throws {
            guard !value.isEmpty else { throw PreferenceError.invalidIdentifier }
        }

        private func object(_ value: AnyJSON?, key: String) throws -> [String: AnyJSON] {
            guard let value else { return [:] }
            guard case .object(let result) = value else { throw PreferenceError.invalidShape(key) }
            return result
        }

        private func strings(_ value: AnyJSON?, key: String) throws -> [String] {
            guard let value else { return [] }
            guard case .array(let values) = value,
                  values.allSatisfy({ $0.stringValue != nil }) else { throw PreferenceError.invalidShape(key) }
            return values.compactMap(\.stringValue)
        }
    }
}
