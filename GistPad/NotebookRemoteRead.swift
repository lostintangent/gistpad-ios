import Foundation
import GistPadInterface
import GistPadSync

struct NotebookRemoteReadProblem: Equatable {
  enum Recovery: Equatable { case retry, reconnect, showNote }

  let message: String
  var recovery: Recovery = .retry

  func status(heading: String, detail: String?) -> GitHubStatusState {
    let recoveryTitle: String
    switch recovery {
    case .retry: recoveryTitle = String(localized: "Retry")
    case .reconnect: recoveryTitle = String(localized: "Reconnect GitHub")
    case .showNote: recoveryTitle = String(localized: "Show Note")
    }
    return .problem(
      .init(
        heading: heading, message: message, recoveryTitle: recoveryTitle, detail: detail))
  }
}

@MainActor
enum NotebookRemoteRead {
  /// The problem a failed GitHub read shows, or nil when a newer request superseded it.
  static func problem(for error: any Error) -> NotebookRemoteReadProblem? {
    if error is CancellationError || (error as? URLError)?.code == .cancelled
      || (error as? DraftError) == .staleGeneration
      || (error as? NotebookActionError) == .staleReview
    {
      return nil
    }
    if needsReconnect(error) {
      return .init(
        message: String(localized: "Reconnect GitHub to check for changes."), recovery: .reconnect)
    }
    return .init(message: NotebookModel.message(for: error))
  }

  static func needsReconnect(_ error: any Error) -> Bool {
    if let error = error as? AccountError {
      return error == .signedOut || error == .reconnectGitHub || error == .accountChanged
    }
    if case .http(401, _)? = error as? GitHubClientError { return true }
    return false
  }
}
