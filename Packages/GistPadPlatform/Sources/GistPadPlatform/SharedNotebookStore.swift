import Foundation
import GistPadSync

public struct SharedNotebookStore: Sendable {
    public static let appGroupIdentifier = "group.dev.gistpad.GistPad"
    public let location: SharedStoreLocation
    private var url: URL { location.directory.appendingPathComponent("notebook.snapshot") }

    public init(location: SharedStoreLocation) {
        self.location = location
    }

    public init() throws {
        self.init(location: try SharedStoreLocation(
            appGroupIdentifier: Self.appGroupIdentifier, prepareDirectory: false))
    }

    public func read() throws -> NotebookSystemSnapshot? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let snapshot = try JSONDecoder().decode(NotebookSystemSnapshot.self, from: data)
        guard snapshot.notes.allSatisfy({ $0.accountID == snapshot.accountID }),
              TimeZone(identifier: snapshot.today.timeZoneIdentifier) != nil,
              Set(snapshot.notes.map(\.id)).count == snapshot.notes.count else {
            throw NotebookPlatformError.invalidSnapshot
        }
        return snapshot
    }

    public func write(_ snapshot: NotebookSystemSnapshot) throws {
        try FileManager.default.createDirectory(
            at: location.directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: location.directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
