import AppIntents
import Foundation

@AppIntent(schema: .notes.appendText)
public struct AppendToGistIntent {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    public var content: AttributedString
    public var target: GistEntity
    @Dependency var dailyNotes: any DailyNoteActions

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<GistEntity> {
        let updated = try await dailyNotes.appendToNote(target, text: String(content.characters))
        return .result(value: updated)
    }
}

@AppIntent(schema: .notes.updateNote)
public struct UpdateGistNoteIntent {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    public var target: GistEntity
    public var name: AttributedString?
    public var attachments: [IntentFile]?
    public var isPinned: Bool?
    public var folder: GistFolderEntity?
    @Dependency var dailyNotes: any DailyNoteActions

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<GistEntity> {
        guard attachments?.isEmpty != false,
              folder == nil || folder?.id == target.folder?.id
        else { throw PlatformError.unsupportedNoteUpdate }
        let updated = try await dailyNotes.updateNote(
            target, name: name.map { String($0.characters) }, isPinned: isPinned)
        return .result(value: updated)
    }
}
