import Foundation

public struct SharedNotebookStore: Sendable {
    private let directory: URL
    private var url: URL { directory.appendingPathComponent("notebook.snapshot") }

    public init() throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.dev.gistpad.GistPad")
        else { throw CocoaError(.fileNoSuchFile) }
        directory = container.appendingPathComponent(
            "Library/Application Support/GistPad", isDirectory: true)
    }

    public func read() throws -> NotebookSystemSnapshot? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        return try JSONDecoder().decode(NotebookSystemSnapshot.self, from: data)
    }

    public func write(_ snapshot: NotebookSystemSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
