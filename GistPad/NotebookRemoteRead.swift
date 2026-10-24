import Foundation
import GistPadInterface
import GistPadSync
import OSLog

enum NotebookRemoteReadError: Error {
  case invalidResult
}

struct NotebookRemoteReadProblem: Equatable {
  enum Recovery: Equatable { case retry, reconnect }

  let message: String
  var recovery: Recovery = .retry
  var retryAfter: Date?

  func status(
    heading: String, detail: String, isRecovering: Bool
  ) -> GitHubStatusState {
    .problem(
      .init(
        heading: heading, message: message,
        recoveryTitle: recovery == .reconnect
          ? String(localized: "Reconnect GitHub") : String(localized: "Retry"),
        detail: detail, isRecovering: isRecovering, retryAfter: retryAfter))
  }
}

@MainActor
enum NotebookRemoteRead {
  static let retryDelays: [Duration] = [.milliseconds(750), .seconds(2)]
  private static let logger = Logger(
    subsystem: "dev.gistpad.GistPad", category: "GitHubRead")

  static func run<Value>(
    retryDelays: [Duration] = retryDelays,
    while isCurrent: () -> Bool,
    operation: () async throws -> Value
  ) async throws -> Value {
    for attempt in 0...retryDelays.count {
      try Task.checkCancellation()
      guard isCurrent() else { throw CancellationError() }
      do {
        let result = try await operation()
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        return result
      } catch {
        guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
        let failure = classify(error)
        guard failure.shouldRetry, attempt < retryDelays.count else {
          if failure.isSuperseded { throw CancellationError() }
          throw error
        }
        logger.debug(
          "Retrying GitHub read after \(String(reflecting: type(of: error)), privacy: .public), attempt \(attempt + 1)")
        try await Task.sleep(for: retryDelays[attempt])
      }
    }
    throw CancellationError()
  }

  static func problem(for error: any Error) -> NotebookRemoteReadProblem? {
    let failure = classify(error)
    return failure.isSuperseded ? nil : failure.problem
  }

  private struct Failure {
    let shouldRetry: Bool
    let isSuperseded: Bool
    let problem: NotebookRemoteReadProblem?
  }

  private static func classify(_ error: any Error) -> Failure {
    let errors = underlyingErrors(error)
    if errors.contains(where: {
      $0 is CancellationError || ($0 as? URLError)?.code == .cancelled
        || ($0 as? DraftError) == .staleGeneration
        || ($0 as? DraftError) == .publishInProgress
        || ($0 as? NotebookActionError) == .staleReview
    }) {
      return .init(shouldRetry: true, isSuperseded: true, problem: nil)
    }
    if errors.contains(where: {
      ($0 as? AccountError) == .signedOut || ($0 as? AccountError) == .reconnectGitHub
        || ($0 as? AccountError) == .accountChanged
        || ($0 as? GitHubClientError).map {
          if case .http(401, _) = $0 { return true }
          return false
        } == true
    }) {
      return .init(
        shouldRetry: false, isSuperseded: false,
        problem: .init(
          message: String(localized: "Reconnect GitHub to check for changes."),
          recovery: .reconnect))
    }
    if errors.contains(where: { $0 is NotebookRemoteReadError }) {
      return .init(
        shouldRetry: false, isSuperseded: false,
        problem: .init(
          message: String(localized: "The update check returned an unexpected result. Try checking again.")))
    }
    for error in errors {
      if case GitHubClientError.http(let status, let retryAfter) = error {
        if status == 429 || status == 403 {
          let message: String
          if let retryAfter, retryAfter > .now {
            message = String(
              localized: "GitHub asked us to wait until \(retryAfter.formatted(date: .omitted, time: .shortened)).")
          } else {
            message = String(
              localized: "GitHub is limiting requests or denied access. Try again later.")
          }
          return .init(
            shouldRetry: false, isSuperseded: false,
            problem: .init(message: message, retryAfter: retryAfter))
        }
        return .init(
          shouldRetry: status == 408 || (500...599).contains(status),
          isSuperseded: false,
          problem: .init(message: NotebookModel.message(for: error)))
      }
      if let error = error as? URLError {
        let message: String
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
          message = String(
            localized: "You're offline. Connect to the internet, then try again.")
        default:
          message = String(
            localized: "GitHub couldn't be reached after trying again.")
        }
        return .init(
          shouldRetry: true, isSuperseded: false, problem: .init(message: message))
      }
    }
    let isDeterministic = errors.contains {
      $0 is NotebookEditError || $0 is DraftError || $0 is DraftMetadataError
        || $0 is NotebookActionError || $0 is GitHubClientError || $0 is AccountError
        || $0 is DecodingError
    }
    return .init(
      shouldRetry: !isDeterministic, isSuperseded: false,
      problem: .init(message: NotebookModel.message(for: error)))
  }

  private static func underlyingErrors(_ error: any Error) -> [any Error] {
    var errors: [any Error] = [error]
    var visited: Set<ObjectIdentifier> = []
    var index = 0
    while index < errors.count, index < 16 {
      let current = errors[index] as NSError
      index += 1
      guard visited.insert(ObjectIdentifier(current)).inserted else { continue }
      if let underlying = current.userInfo[NSUnderlyingErrorKey] as? any Error {
        errors.append(underlying)
      }
      if let underlying = current.userInfo[NSMultipleUnderlyingErrorsKey] as? [any Error] {
        errors.append(contentsOf: underlying.prefix(16 - min(errors.count, 16)))
      }
    }
    return Array(errors.prefix(16))
  }
}
