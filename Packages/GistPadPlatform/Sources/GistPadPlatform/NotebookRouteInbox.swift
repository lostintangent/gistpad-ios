import Foundation
import Observation

public struct NotebookRouteRequest: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let route: NotebookRoute
}

@MainActor @Observable
public final class NotebookRouteInbox {
    public static let shared = NotebookRouteInbox()
    public private(set) var pending: NotebookRouteRequest?

    public init() {}

    public func submit(_ route: NotebookRoute) {
        pending = NotebookRouteRequest(route: route)
    }

    public func acknowledge(_ requestID: UUID) {
        guard pending?.id == requestID else { return }
        pending = nil
    }
}
