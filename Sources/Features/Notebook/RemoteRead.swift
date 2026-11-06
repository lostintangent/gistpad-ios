import Foundation
import Interface
import Sync

public struct RemoteReadProblem: Equatable {
  public enum Recovery: Equatable { case retry, reconnect }

  let message: String
  public var recovery: Recovery = .retry

  func status(heading: String, detail: String?) -> GitHubStatusState {
    let recoveryTitle = switch recovery {
    case .retry: String(localized: "Try Again")
    case .reconnect: String(localized: "Reconnect GitHub")
    }
    return .problem(
      .init(
        heading: heading, message: message, recoveryTitle: recoveryTitle, detail: detail))
  }
}

@MainActor
public enum RemoteRead {
  /// The problem a failed GitHub read shows, or nil when a newer request superseded it.
  static func problem(for error: any Error) -> RemoteReadProblem? {
    if error is CancellationError || (error as? URLError)?.code == .cancelled
      || (error as? DraftError) == .staleGeneration
      || (error as? ChangeError) == .staleReview
    {
      return nil
    }
    if needsReconnect(error) {
      return .init(
        message: String(localized: "Reconnect GitHub to check for changes."), recovery: .reconnect)
    }
    return .init(message: error.localizedDescription)
  }

  static func needsReconnect(_ error: any Error) -> Bool {
    if let error = error as? AccountError {
      return error == .signedOut || error == .reconnectGitHub || error == .accountChanged
    }
    if case .http(401)? = error as? GitHubClientError { return true }
    return false
  }
}
