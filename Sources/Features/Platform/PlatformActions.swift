import Foundation
import Store

/// What intents ask of the app, provided through `AppDependencyManager`.
@MainActor
public protocol PlatformActions: AnyObject, Sendable {
    func validateAccount(_ accountID: UUID) async throws
    func noteEntities(for identifiers: [String]) async throws -> [GistFileEntity]
    func createNote(name: String, content: String?) async throws -> GistFileEntity
    @discardableResult
    func addToToday(text: String, asTask: Bool, target: DailyNote.Day) async throws -> GistPadLink
    func appendToNote(_ note: GistFileEntity, text: String) async throws -> GistFileEntity
    func updateNote(_ note: GistFileEntity, name: String?, isPinned: Bool?) async throws -> GistFileEntity
}

public enum PlatformError: LocalizedError, Equatable, Sendable {
    case accountChanged
    case editingInProgress
    case emptyNoteText
    case emptyNoteName
    case unsupportedNoteCreation
    case unsupportedNoteUpdate

    public var errorDescription: String? {
        switch self {
        case .accountChanged:
            String(localized: "Open GistPad and sign in to the account this action uses.")
        case .editingInProgress:
            String(localized: "Finish typing in GistPad, then try again.")
        case .emptyNoteText:
            String(localized: "Say or type something to add to this note.")
        case .emptyNoteName:
            String(localized: "Give the new note a name.")
        case .unsupportedNoteCreation:
            String(localized: "Siri can’t create a pinned note, add attachments, or put it in an existing gist.")
        case .unsupportedNoteUpdate:
            String(localized: "Siri can’t make that change to this gist. Open it in GistPad instead.")
        }
    }
}
