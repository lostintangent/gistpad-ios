import AppIntents
import Foundation

public struct OpenGistIntent: OpenIntent {
    public static let title: LocalizedStringResource = "Open Gist"
    public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Gist") public var target: GistEntity
    public init() {}
    public init(target: GistEntity) { self.target = target }

    @MainActor
    public func perform() async throws -> some IntentResult {
        PendingLink.shared.link = target.link
        return .result()
    }
}

public struct NewGistIntent: AppIntent {
    public static let title: LocalizedStringResource = "New Gist"
    public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        PendingLink.shared.link = .newGist
        return .result()
    }
}

public struct GistPadPlatformIntents: AppIntentsPackage {}
