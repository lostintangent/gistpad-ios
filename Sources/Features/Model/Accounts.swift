import AuthenticationServices
import Comments
import Editor
import Foundation
import Store

// One GitHub account at a time. Signing in as someone else keeps your drafts until you choose.

extension GistPadModel {
  public func start() async {
    guard !isStarting, !isSigningOut else { return }
    isStarting = true
    defer { isStarting = false }
    let request = UUID()
    libraryRequest = request
    state.loadState = .loading
    do {
      let restored = try await accountStore.connectedAccount()
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
      let signedIn = try await accountStore.signIn()
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
    for fileEditor in editors.values {
      guard !fileEditor.isPublishing, !fileEditor.isApplyingDurableEdit else {
        throw ChangeError.publicationInProgress
      }
      guard fileEditor.editor.isSettled else { throw Edit.MutationError.compositionActive }
      guard await fileEditor.waitForLocalSave() else { throw EditError.localPersistenceFailed }
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

  /// The signed-in account, with this iPhone's drafts and cache loaded but nothing read from
  /// GitHub. App Intents use it, since they can run before the app's window starts the model.
  public func localAccount() async throws -> GistPadAccount? {
    guard pendingAccount == nil, !isSigningIn, !isSigningOut else {
      throw AccountError.accountChanged
    }
    if let account { return account }
    guard let restored = try await accountStore.connectedAccount() else { return nil }
    if let account { return account }
    account = restored
    try await reloadLocalState(accountID: restored.id)
    return restored
  }

  /// Uploads an image to GistPad's public storage, filed under the file's gist.
  public func uploadImage(_ image: Data, for file: GistFile) async throws -> URL {
    guard account?.id == file.accountID, pendingAccount == nil else {
      throw AccountError.accountChanged
    }
    guard let gistID = file.current.gistID else { throw DraftError.notFound }
    let storage = try await accountStore.imageStorage(accountID: file.accountID)
    return try await storage.upload(image, gistID: gistID)
  }

  /// A gist's conversation, which you take part in as the signed-in account.
  public func comments(for gist: Gist) async throws -> CommentsModel {
    guard let account, pendingAccount == nil else { throw AccountError.accountChanged }
    let github = await client(accountID: account.id)
    let userID =
      if let id = account.githubUserID { id } else { try await github.authenticatedUser().id }
    return CommentsModel(
      gistID: gist.id, userID: userID, gistOwnerID: gist.owner?.id, remote: github)
  }

  /// Drops everything shown for the current account and switches to `account`, or signs out.
  func reset(to account: GistPadAccount?) {
    libraryRequest = UUID()
    fileRequest = UUID()
    self.account = account
    pendingAccount = nil
    loadedFile = nil
    opening = nil
    editors = [:]
    drafts = []
    gistCache = nil
    openError = nil
    remoteRefreshProblem = nil
    isRefreshingRemote = false
    state.replace(gists: [], known: false)
    state.selectedID = nil
    state.clearFilters()
    if account == nil { state.loadState = .signedOut }
  }
}
