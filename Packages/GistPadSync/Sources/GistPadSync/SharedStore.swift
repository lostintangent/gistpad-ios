import Foundation

public enum SharedStoreError: Error, Equatable, Sendable {
    case unavailableAppGroup
    case invalidContainer
    case duplicateCommand
    case invalidCommand
}

public struct SharedStoreLocation: Sendable {
    public let directory: URL

    public init(appGroupIdentifier: String, prepareDirectory: Bool = true) throws {
        guard appGroupIdentifier.hasPrefix("group."),
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
              ) else { throw SharedStoreError.unavailableAppGroup }
        try self.init(containerURL: container, prepareDirectory: prepareDirectory)
    }

    public init(containerURL: URL, prepareDirectory: Bool = true) throws {
        guard containerURL.isFileURL, containerURL.hasDirectoryPath else {
            throw SharedStoreError.invalidContainer
        }
        directory = containerURL.appendingPathComponent("Library/Application Support/GistPad", isDirectory: true)
        guard prepareDirectory else { return }
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

func encodedCommand(_ command: SharedDraftCommand) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(command)
}
