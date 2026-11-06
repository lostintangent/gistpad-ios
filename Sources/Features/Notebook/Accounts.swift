import AuthenticationServices
import Editor
import Foundation
import Sync

// One GitHub account at a time. Signing in as someone else keeps your drafts until you choose.

extension Library {
  public func start() async {
    guard !isStarting, !isSigningOut else { return }
    isStarting = true
    defer { isStarting = false }
    let request = UUID()
    libraryRequest = request
    state.loadState = .loading
    do {
      let restored = try await sync.connectedAccount()
      guard request == libraryRequest else { return }
      guard let restored else {
        state.loadState = .signedOut
        return
      }
      account = restored
      try await reloadLocalState(accountID: restored.id)
      isStarting = false
      await refresh()
      await restoreLastOpened()
    } catch is CancellationError {
      if request == libraryRequest {
        state.loadState = account == nil ? .signedOut : .ready
      }
    } catch {
      guard request == libraryRequest else { return }
      report(error, operation: "restore")
      state.loadState = .failed(message: error.localizedDescription)
    }
  }

  public func signIn() async {
    guard !isSigningIn, !isSigningOut else { return }
    isSigningIn = true
    let previousState = state.loadState
    defer { isSigningIn = false }
    do {
      let signedIn = try await sync.signIn()
      libraryRequest = UUID()
      if let account, account.id != signedIn.id {
        pendingAccount = signedIn
        state.loadState = .reconnectRequired(
          message: String(
            localized:
              "A different GitHub account signed in. Keep the current account or switch to it."
          ))
        return
      }
      account = signedIn
      pendingAccount = nil
      try await reloadLocalState(accountID: signedIn.id)
      await refresh()
      await restoreLastOpened()
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      state.loadState = previousState
    } catch is CancellationError {
      state.loadState = previousState
    } catch {
      libraryRequest = UUID()
      report(error, operation: "sign-in")
      state.loadState = .reconnectRequired(message: error.localizedDescription)
    }
  }

  /// Switches to the account that just signed in, once every open file is saved on this iPhone.
  public func switchAccount() async throws {
    guard let pendingAccount else { return }
    for session in sessions.values {
      guard !session.isPublishing, !session.isApplyingDurableEdit else {
        throw ChangeError.publicationInProgress
      }
      guard session.editor.isSettled else { throw Edit.MutationError.compositionActive }
      guard await session.waitForLocalSave() else { throw EditError.localPersistenceFailed }
    }
    guard self.pendingAccount == pendingAccount else { return }
    reset(to: pendingAccount)
    do {
      try await reloadLocalState(accountID: pendingAccount.id)
    } catch {
      report(error, operation: "reload-local")
      openError = error.localizedDescription
    }
    await refresh()
    await restoreLastOpened()
  }

  public func keepCurrentAccount() {
    pendingAccount = nil
    state.loadState = .reconnectRequired(
      message: String(
        localized:
          "Your drafts are kept on this iPhone. Reconnect the original account to publish them."
      ))
  }

  public func uploadImage(_ image: Data, gistID: String, accountID: UUID) async throws -> URL {
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
    return try await sync.uploadImage(image, gistID: gistID, accountID: accountID)
  }

  public func comments(accountID: UUID) async throws -> CommentServices {
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
    return try await sync.comments(accountID: accountID)
  }

  /// Drops everything shown for the current account and switches to `account`, or signs out.
  func reset(to account: Account?) {
    libraryRequest = UUID()
    fileRequest = UUID()
    self.account = account
    pendingAccount = nil
    loadedFile = nil
    opening = nil
    sessions = [:]
    localDrafts = []
    cachedLibrary = nil
    openError = nil
    remoteRefreshProblem = nil
    isRefreshingRemote = false
    state.replace(gists: [], known: false)
    state.selectedID = nil
    state.clearFilters()
    if account == nil { state.loadState = .signedOut }
  }
}
