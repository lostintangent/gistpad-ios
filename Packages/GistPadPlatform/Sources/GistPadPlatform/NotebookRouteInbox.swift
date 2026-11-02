import Observation

@MainActor @Observable
public final class NotebookRouteInbox {
    public static let shared = NotebookRouteInbox()
    public private(set) var pending: NotebookRoute?

    public init() {}

    public func submit(_ route: NotebookRoute) {
        pending = route
    }

    public func clear() {
        pending = nil
    }
}
