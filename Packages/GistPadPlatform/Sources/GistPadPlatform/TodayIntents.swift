#if os(iOS)
import AppIntents
import Foundation
import GistPadSync

public struct SetTaskIntent: AppIntent {
    public static let title: LocalizedStringResource = "Set Task"
    public static var supportedModes: IntentModes { .background }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    public static var isDiscoverable: Bool { false }

    @Parameter(title: "Task") public var taskID: Int
    @Parameter(title: "Completed") public var completed: Bool
    @Dependency private var dailyNotes: any DailyNoteActions

    public init() {}
    public init(task: FileTask, completed: Bool) {
        taskID = task.id
        self.completed = completed
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        try await dailyNotes.setTask(id: taskID, completed: completed)
        return .result()
    }
}

public struct AddToTodayIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add to Today"
    public static let description = IntentDescription(
        "Adds text or a task to today's note.")
    public static var supportedModes: IntentModes { .background }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Text", requestValueDialog: "What would you like to add to Today?")
    public var text: String
    @Parameter(title: "As Task", default: false) public var asTask: Bool
    @Dependency var dailyNotes: any DailyNoteActions

    public static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to Today") { \.$asTask }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        try await dailyNotes.addToToday(text: text, asTask: asTask, target: DailyNote.Day())
        return .result(dialog: "Added to Today.")
    }
}

public struct ShowAddToTodayIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add to Today"
    public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    public static var isDiscoverable: Bool { false }
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        PendingLink.shared.link = .addToToday
        return .result()
    }
}
#endif
