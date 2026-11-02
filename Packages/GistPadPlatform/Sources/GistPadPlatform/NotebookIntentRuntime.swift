import Foundation
import GistPadSync

@MainActor
public protocol NotebookIntentServing: AnyObject, Sendable {
    func validateAccount(_ accountID: UUID) async throws
    func setTask(id: Int, completed: Bool) async throws
    @discardableResult
    func addToToday(text: String, asTask: Bool, target: DailyNote.Day) async throws -> NotebookRoute
}
