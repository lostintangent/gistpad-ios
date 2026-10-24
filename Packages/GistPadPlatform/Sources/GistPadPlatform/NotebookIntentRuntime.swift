import Foundation
import GistPadSync

@MainActor
public protocol NotebookIntentServing: AnyObject, Sendable {
    func validateAccount(_ accountID: UUID) async throws
    func setTask(id: String, completed: Bool) async throws
    @discardableResult
    func addToToday(text: String, asTask: Bool, target: DailyNoteTarget) async throws -> NotebookRoute
}

@MainActor
public enum NotebookIntentRuntime {
    private static var factory: (@MainActor () throws -> any NotebookIntentServing)?

    public static func configure(
        _ factory: @escaping @MainActor () throws -> any NotebookIntentServing
    ) {
        self.factory = factory
    }

    public static func service() throws -> any NotebookIntentServing {
        guard let factory else { throw NotebookPlatformError.serviceUnavailable }
        return try factory()
    }
}

public enum TodayAppend {
    public static func command(
        draft: DraftSnapshot, text: String, asTask: Bool
    ) throws -> SharedDraftCommand {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotebookPlatformError.emptyText
        }
        let content: String
        if asTask {
            content = text.split(whereSeparator: \.isNewline).map {
                "- [ ] " + $0.trimmingCharacters(in: .whitespaces)
            }.joined(separator: "\n")
        } else {
            content = text.trimmingCharacters(in: .newlines)
        }
        let separator: String
        if draft.text.isEmpty || draft.text.hasSuffix(asTask ? "\n" : "\n\n") {
            separator = ""
        } else if asTask || draft.text.hasSuffix("\n") {
            separator = "\n"
        } else {
            separator = "\n\n"
        }
        return SharedDraftCommand(
            accountID: draft.accountID, draftID: draft.id, expectedGeneration: draft.generation,
            edit: DraftSourceEdit(
                location: draft.text.utf16.count, length: 0, expectedText: "",
                replacement: separator + content + "\n"))
    }
}
