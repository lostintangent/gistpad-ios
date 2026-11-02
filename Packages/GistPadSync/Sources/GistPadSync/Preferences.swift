import Auth
import Foundation

public typealias MetadataValue = AnyJSON

public struct Preferences: Codable, Equatable, Sendable {
    public let metadata: [String: MetadataValue]

    public init(metadata: [String: MetadataValue]) { self.metadata = metadata }

    public var isEmpty: Bool { metadata.isEmpty }

    public init(isAutoSaveEnabled: Bool, accentColor: String?) {
        var metadata: [String: MetadataValue] = ["isAutoSaveEnabled": .bool(isAutoSaveEnabled)]
        metadata["accentColor"] = accentColor.map(MetadataValue.string)
        self.init(metadata: metadata)
    }

    public func booleanValue(_ preference: BooleanPreference, default fallback: Bool = true) -> Bool {
        metadata[preference.rawValue]?.boolValue ?? fallback
    }

    public var profileDisplayName: String? {
        for key in ["full_name", "name"] {
            if let value = metadata[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    public var tags: [Tag] {
        tagMetadata.map { id, value in
            Tag(
                id: id, name: value.objectValue?["name"]?.stringValue ?? id,
                colorHex: value.objectValue?["color"]?.stringValue)
        }
    }

    public func applying(_ change: Change) throws -> Preferences {
        Preferences(metadata: metadata.merging(try change.changes(in: metadata)) { _, new in new })
    }

    public var isAutoSaveEnabled: Bool { metadata["isAutoSaveEnabled"]?.boolValue ?? true }
    public var accentColor: String? { metadata["accentColor"]?.stringValue }
    public var pinnedGists: [String] {
        metadata["pinnedGists"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
    private var tagMetadata: [String: MetadataValue] { metadata["tags"]?.objectValue ?? [:] }
    public var gistTags: [String: [String]] {
        (metadata["gistTags"]?.objectValue ?? [:]).mapValues {
            $0.arrayValue?.compactMap(\.stringValue) ?? []
        }
    }

    public struct Tag: Equatable, Sendable {
        public let id: String
        public let name: String
        public let colorHex: String?
    }

    public func tagNames(gistID: String) -> [String] {
        (gistTags[gistID] ?? []).compactMap { tagMetadata[$0]?.objectValue?["name"]?.stringValue }
    }
}

public enum PreferenceError: Error, Equatable, Sendable {
    case invalidShape(String)
    case invalidIdentifier
    case unknownTag
    case operationInProgress
}

extension PreferenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownTag: String(localized: "This tag no longer exists.")
        case .operationInProgress: String(localized: "Another change is still saving. Try again in a moment.")
        case .invalidShape: String(localized: "GistPad can't safely make this change. Make it on gistpad.dev.")
        case .invalidIdentifier: String(localized: "This change couldn't be saved. Try again.")
        }
    }
}

public enum BooleanPreference: String, Sendable {
    case isAutoSaveEnabled, showDiffs, showFrontmatter, showLineNumbers, isSpellcheckEnabled
    case pasteImagesAsHtml, showArchivedGists, showStarredGists, showInlineComments
    case showFormattingToolbar
}

extension Preferences {
    /// One edit to the account metadata the web shares, like a pin, a tag or a preference.
    public enum Change: Equatable, Sendable {
        case setBoolean(BooleanPreference, Bool)
        case setAccentColor(String)
        case setPinned(gistID: String, pinned: Bool)
        case upsertTag(id: String, name: String, color: String?)
        case deleteTag(id: String)
        case setTag(gistID: String, tagID: String, included: Bool)

        public func changes(in metadata: [String: MetadataValue]) throws -> [String: MetadataValue] {
            switch self {
            case .setBoolean(let preference, let value):
                return [preference.rawValue: .bool(value)]
            case .setAccentColor(let hex):
                guard hex.first == "#", hex.utf8.count == 7,
                      hex.dropFirst().utf8.allSatisfy({
                          (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                      }) else { throw PreferenceError.invalidShape("accentColor") }
                return ["accentColor": .string(hex)]
            case .setPinned(let gistID, let pinned):
                try requireID(gistID)
                var pins = try strings(metadata["pinnedGists"], key: "pinnedGists")
                if pinned, !pins.contains(gistID) { pins.append(gistID) }
                if !pinned { pins.removeAll { $0 == gistID } }
                return ["pinnedGists": .array(pins.map(MetadataValue.string))]
            case .upsertTag(let id, let name, let color):
                try requireID(id)
                var tags = try object(metadata["tags"], key: "tags")
                var tag = try object(tags[id], key: "tags.\(id)")
                tag["name"] = .string(name)
                tag["color"] = color.map(MetadataValue.string)
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
                    else { gistTags[gist] = .array(ids.map(MetadataValue.string)) }
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
                else { gistTags[gistID] = .array(ids.map(MetadataValue.string)) }
                return ["gistTags": .object(gistTags)]
            }
        }

        private func requireID(_ value: String) throws {
            guard !value.isEmpty else { throw PreferenceError.invalidIdentifier }
        }

        private func object(_ value: MetadataValue?, key: String) throws -> [String: MetadataValue] {
            guard let value else { return [:] }
            guard case .object(let result) = value else { throw PreferenceError.invalidShape(key) }
            return result
        }

        private func strings(_ value: MetadataValue?, key: String) throws -> [String] {
            guard let value else { return [] }
            guard case .array(let values) = value,
                  values.allSatisfy({ $0.stringValue != nil }) else { throw PreferenceError.invalidShape(key) }
            return values.compactMap(\.stringValue)
        }
    }
}
