import Foundation
import GistPadSync

/// What intents ask of the app, provided through `AppDependencyManager`.
@MainActor
public protocol DailyNoteActions: AnyObject, Sendable {
    func validateAccount(_ accountID: UUID) async throws
    @discardableResult
    func addToToday(text: String, asTask: Bool, target: DailyNote.Day) async throws -> GistPadLink
}
