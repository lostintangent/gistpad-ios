import Foundation

public enum SharedStoreError: Error, Equatable, Sendable {
    case unavailableAppGroup
    case invalidContainer
    case duplicateCommand
    case invalidCommand
}

public struct SharedStoreLocation: Sendable {
    public let directory: URL
    public var storeURL: URL { directory.appendingPathComponent("drafts.store") }
    public var inboxURL: URL { directory.appendingPathComponent("inbox", isDirectory: true) }

    public init(appGroupIdentifier: String) throws {
        guard appGroupIdentifier.hasPrefix("group."),
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
              ) else { throw SharedStoreError.unavailableAppGroup }
        try self.init(containerURL: container)
    }

    public init(containerURL: URL) throws {
        guard containerURL.isFileURL, containerURL.hasDirectoryPath else {
            throw SharedStoreError.invalidContainer
        }
        directory = containerURL.appendingPathComponent("Library/Application Support/GistPad", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
    }
}

public struct DraftSourceEdit: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int
    public let expectedText: String
    public let replacement: String

    public init(location: Int, length: Int, expectedText: String, replacement: String) {
        self.location = location
        self.length = length
        self.expectedText = expectedText
        self.replacement = replacement
    }

    func apply(to text: String) throws -> String {
        let source = text as NSString
        guard location >= 0, length >= 0, location <= source.length,
              length <= source.length - location else { throw SharedStoreError.invalidCommand }
        let range = NSRange(location: location, length: length)
        guard isScalarBoundary(location, in: source), isScalarBoundary(location + length, in: source),
              sourceEqual(source.substring(with: range), expectedText) else {
            throw SharedStoreError.invalidCommand
        }
        return source.replacingCharacters(in: range, with: replacement)
    }

    private func isScalarBoundary(_ offset: Int, in source: NSString) -> Bool {
        guard offset > 0, offset < source.length else { return true }
        return !(0xD800...0xDBFF).contains(source.character(at: offset - 1))
            || !(0xDC00...0xDFFF).contains(source.character(at: offset))
    }
}

public struct SharedDraftCommand: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let accountID: UUID
    public let draftID: UUID
    public let expectedGeneration: UInt64
    public let edit: DraftSourceEdit

    public init(
        id: UUID = UUID(), accountID: UUID, draftID: UUID,
        expectedGeneration: UInt64, edit: DraftSourceEdit
    ) {
        self.id = id
        self.accountID = accountID
        self.draftID = draftID
        self.expectedGeneration = expectedGeneration
        self.edit = edit
    }
}

public actor SharedDraftInbox {
    private let directory: URL

    public init(location: SharedStoreLocation) throws {
        directory = location.inboxURL
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
    }

    public func enqueue(_ command: SharedDraftCommand) throws {
        let data = try encodedCommand(command)
        let accountDirectory = directory.appendingPathComponent(command.accountID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: accountDirectory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let url = fileURL(command)
        let staged = accountDirectory.appendingPathComponent("\(UUID().uuidString).pending")
        try data.write(to: staged, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: staged) }
        // A hard link publishes a complete immutable file without replacing another process's command.
        do { try FileManager.default.linkItem(at: staged, to: url) }
        catch let error as CocoaError where error.code == .fileWriteFileExists {
            guard try Data(contentsOf: url) == data else { throw SharedStoreError.duplicateCommand }
        }
    }

    public func pending(accountID: UUID) throws -> [SharedDraftCommand] {
        let accountDirectory = directory.appendingPathComponent(accountID.uuidString, isDirectory: true)
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: accountDirectory, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return try files
            .filter { $0.pathExtension == "json" }
            .map {
                let command = try JSONDecoder().decode(SharedDraftCommand.self, from: Data(contentsOf: $0))
                guard command.accountID == accountID, $0.lastPathComponent == "\(command.id.uuidString).json" else {
                    throw SharedStoreError.invalidCommand
                }
                return command
            }
            .sorted {
                if $0.draftID != $1.draftID { return $0.draftID.uuidString < $1.draftID.uuidString }
                if $0.expectedGeneration != $1.expectedGeneration {
                    return $0.expectedGeneration < $1.expectedGeneration
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    public func acknowledge(_ command: SharedDraftCommand) throws {
        let url = fileURL(command)
        guard try Data(contentsOf: url) == encodedCommand(command) else {
            throw SharedStoreError.duplicateCommand
        }
        try FileManager.default.removeItem(at: url)
    }

    private func fileURL(_ command: SharedDraftCommand) -> URL {
        directory.appendingPathComponent(command.accountID.uuidString, isDirectory: true)
            .appendingPathComponent("\(command.id.uuidString).json")
    }
}

extension DraftStore {
    public static func open(location: SharedStoreLocation) throws -> DraftStore {
        try open(url: location.storeURL)
    }
}

func encodedCommand(_ command: SharedDraftCommand) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(command)
}
