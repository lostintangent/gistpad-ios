import AuthenticationServices
import Comments
import Editor
import Foundation
import Store

// One GitHub account at a time. Signing in as someone else keeps your drafts until you choose.

public enum Phase: Equatable, Sendable {
  case signedOut
  case signingIn
  /// Restoring the account and this iPhone's drafts at launch.
  case loading
  case ready
  /// Reading your gists from GitHub.
  case refreshing
  /// Someone else signed in over your account, until you choose which to keep.
  case switching(to: GistPadAccount)
  case signingOut

  /// The account that signed in over yours, while you choose.
  public var switchingTo: GistPadAccount? {
    if case .switching(let account) = self { account } else { nil }
  }

  /// Signing in, switching or signing out, while the account may change under you.
  public var isChangingAccount: Bool {
    switch self {
    case .signingIn, .switching, .signingOut: true
    default: false
    }
  }
}

extension GistPadModel {
  public func start() async {
    guard phase != .signingOut else { return }
    let request = UUID()
    libraryRequest = request
    phase = .loading
    do {
      let restored = try await accountStore.connectedAccount()
      guard request == libraryRequest else { return }
      guard let restored else {
        phase = .signedOut
        return
      }
      account = restored
      try await reloadLocalState(accountID: restored.id)
      await refresh()
      await restoreLastOpened()
    } catch {
      guard request == libraryRequest else { return }
      phase = account == nil ? .signedOut : .ready
      guard !(error is CancellationError) else { return }
      report(error, operation: "restore")
      openError = error.localizedDescription
    }
  }

  public func signIn() async {
    guard !phase.isChangingAccount else { return }
    phase = .signingIn
    do {
      let signedIn = try await accountStore.signIn()
      libraryRequest = UUID()
      if let account, account.id != signedIn.id {
        phase = .switching(to: signedIn)
        return
      }
      account = signedIn
      phase = .ready
      try await reloadLocalState(accountID: signedIn.id)
      await refresh()
      await restoreLastOpened()
    } catch {
      if phase == .signingIn { phase = account == nil ? .signedOut : .ready }
      if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
        || error is CancellationError
      {
        return
      }
      libraryRequest = UUID()
      report(error, operation: "sign-in")
      openError = error.localizedDescription
    }
  }

  /// Switches to the account that just signed in, once every open file is saved on this iPhone.
  public func switchAccount() async throws {
    guard let pendingAccount = phase.switchingTo else { return }
    for fileEditor in editors.values {
      guard !fileEditor.isPublishing, !fileEditor.isApplyingDurableEdit else {
        throw ChangeError.publicationInProgress
      }
      guard fileEditor.editor.isSettled else { throw Edit.MutationError.compositionActive }
      guard await fileEditor.waitForLocalSave() else { throw EditError.localPersistenceFailed }
    }
    guard phase.switchingTo == pendingAccount else { return }
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

  /// Keeps your drafts on this iPhone until the original account reconnects to publish them.
  public func keepCurrentAccount() {
    phase = .ready
    problem = .reconnect
  }

  /// The signed-in account, with this iPhone's drafts and cache loaded but nothing read from
  /// GitHub. App Intents use it, since they can run before the app's window starts the model.
  public func localAccount() async throws -> GistPadAccount? {
    guard !phase.isChangingAccount else {
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
    guard account?.id == file.accountID, phase.switchingTo == nil else {
      throw AccountError.accountChanged
    }
    guard let gistID = file.gistID else { throw DraftError.notFound }
    let storage = try await accountStore.imageStorage(accountID: file.accountID)
    return try await storage.upload(image, gistID: gistID)
  }

  /// A gist's conversation, which you take part in as the signed-in account.
  public func comments(for gist: Gist) async throws -> CommentsModel {
    guard let account, phase.switchingTo == nil else { throw AccountError.accountChanged }
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
    phase = account == nil ? .signedOut : .ready
    loadedFile = nil
    opening = nil
    editors = [:]
    drafts = []
    gistCache = nil
    openError = nil
    problem = nil
    state.replace(gists: [], known: false)
    state.selectedID = nil
    state.clearFilters()
  }
}
