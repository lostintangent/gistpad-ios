import Auth
import Foundation

/// Something you asked for that didn't happen: why, in one true sentence, and the one thing that
/// may fix it. An alert also says what didn't happen.
public struct Failure: Error, Equatable, Sendable {
    public enum Action: Sendable {
        /// GitHub may answer next time.
        case tryAgain
        /// GitHub needs you to sign in again.
        case reconnect
    }

    /// What didn't happen, like `Couldn’t Pin “Ideas”`, for an alert. A failure shown in place
    /// reads under its view's own title instead.
    public var title: String?
    public let message: String
    /// Nothing offers a fix when neither trying again nor signing in would help.
    public let action: Action?

    public init(_ message: String, action: Action? = nil, title: String? = nil) {
        self.title = title
        self.message = message
        self.action = action
    }

    /// Why `error` stopped what you asked for. GistPad's own errors keep their sentence, and anything
    /// else, offline included, says GitHub couldn't be reached rather than the system's wording.
    public init(_ error: any Error, title: String? = nil) {
        switch error {
        case let failure as Failure:
            self = failure
        case GitHubError.http(status: 401), AccountError.signedOut, AccountError.accountChanged,
            AccountError.reconnectGitHub, AccountError.keychain:
            self.init(error.localizedDescription, action: .reconnect)
        case is AuthError:
            // Supabase answered and refused the session. Offline reaches us as a URLError instead.
            self.init(AccountError.signedOut)
        case GitHubError.http(status: 404):
            self.init(error.localizedDescription)
        case GitHubError.invalidResponse, GitHubError.http, DraftError.notConfirmed, ImageError.http:
            self.init(error.localizedDescription, action: .tryAgain)
        case _ where !(error is any LocalizedError):
            self.init(String(localized: "GitHub couldn’t be reached."), action: .tryAgain)
        default:
            self.init(error.localizedDescription)
        }
        if let title { self.title = title }
    }
}

extension Failure: LocalizedError {
    public var errorDescription: String? { title ?? message }
}
