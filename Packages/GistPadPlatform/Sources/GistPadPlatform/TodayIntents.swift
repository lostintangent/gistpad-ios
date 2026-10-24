#if os(iOS)
import AppIntents
import Foundation
import GistPadSync
import WidgetKit

public struct SetTodayTaskIntent: AppIntent {
    public static let title: LocalizedStringResource = "Set Today Task"
    public static var supportedModes: IntentModes { .background }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    public static var isDiscoverable: Bool { false }

    @Parameter(title: "Task") public var taskID: String
    @Parameter(title: "Completed") public var completed: Bool

    public init() {}
    public init(task: TodayTask, completed: Bool) {
        taskID = task.id
        self.completed = completed
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        try await NotebookIntentRuntime.service().setTask(id: taskID, completed: completed)
        WidgetCenter.shared.reloadTimelines(ofKind: "GistPadToday")
        return .result()
    }
}

public struct AddToTodayIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add to Today"
    public static let description = IntentDescription(
        "Append text or a task to today's daily note in your notebook.")
    public static var supportedModes: IntentModes { .background }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Text", requestValueDialog: "What would you like to add to Today?")
    public var text: String
    @Parameter(title: "As Task", default: false) public var asTask: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to Today") { \.$asTask }
    }

    public init() {}
    public init(text: String, asTask: Bool = false) {
        self.text = text
        self.asTask = asTask
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = DailyNoteTarget()
        try await NotebookIntentRuntime.service().addToToday(
            text: text, asTask: asTask, target: target)
        WidgetCenter.shared.reloadTimelines(ofKind: "GistPadToday")
        return .result(dialog: "Added to Today.")
    }
}

public struct CaptureTodayIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add to Today"
    public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    public static var isDiscoverable: Bool { false }
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        NotebookRouteInbox.shared.submit(.addToToday)
        return .result()
    }
}
#endif
