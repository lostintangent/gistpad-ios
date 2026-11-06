import Foundation
import Store

/// What intents ask of the app, provided through `AppDependencyManager`.
@MainActor
public protocol DailyNoteActions: AnyObject, Sendable {
    func validateAccount(_ accountID: UUID) async throws
    func noteEntities(for identifiers: [String]) async throws -> [GistEntity]
    func createNote(name: String, content: String?) async throws -> GistEntity
    @discardableResult
    func addToToday(text: String, asTask: Bool, target: DailyNote.Day) async throws -> GistPadLink
    func appendToNote(_ note: GistEntity, text: String) async throws -> GistEntity
    func updateNote(_ note: GistEntity, name: String?, isPinned: Bool?) async throws -> GistEntity
}
