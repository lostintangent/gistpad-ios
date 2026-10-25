import Foundation
import GistPadComments
import GistPadSync

struct NotebookCommentServices: Sendable {
  let remote: any CommentConversationRemote
  let userID: Int64
}

protocol NotebookCommentProviding: Sendable {
  func commentServices(accountID: UUID) async throws -> NotebookCommentServices
}

enum NotebookCommentError: Error {
  case unavailable
}

extension LiveNotebookProvider: NotebookCommentProviding {
  func commentServices(accountID: UUID) async throws -> NotebookCommentServices {
    guard let account = try await accounts.cachedAccount(), account.id == accountID else {
      throw AccountError.accountChanged
    }
    let client = await client(accountID: accountID)
    let userID: Int64
    if let cachedID = account.githubUserID {
      userID = cachedID
    } else {
      userID = try await client.authenticatedUser().id
    }
    guard try await accounts.cachedAccount()?.id == accountID else {
      throw AccountError.accountChanged
    }
    return NotebookCommentServices(remote: GitHubCommentRemote(client: client), userID: userID)
  }
}

@MainActor
final class NotebookCommentProvider {
  private let notebook: NotebookModel
  private let store: any CommentConversationStore
  private var conversations: [CommentConversationScope: CommentConversationController] = [:]

  init(notebook: NotebookModel, store: any CommentConversationStore) {
    self.notebook = notebook
    self.store = store
  }

  convenience init(notebook: NotebookModel) throws {
    self.init(notebook: notebook, store: try CommentConversationDiskStore.applicationStore())
  }

  func conversation(for document: NotebookDocument) async throws -> CommentConversationController {
    guard notebook.account?.id == document.accountID, notebook.pendingAccount == nil else {
      throw AccountError.accountChanged
    }
    guard let gist = document.gist, !gist.isDailyNote, !document.isRecovery else {
      throw NotebookCommentError.unavailable
    }
    let scope = CommentConversationScope(accountID: document.accountID, gistID: gist.id)
    if let existing = conversations[scope] {
      await existing.prepare()
      guard notebook.account?.id == document.accountID, notebook.pendingAccount == nil else {
        throw AccountError.accountChanged
      }
      return existing
    }
    let services = try await notebook.commentServices(accountID: document.accountID)
    guard notebook.account?.id == document.accountID, notebook.pendingAccount == nil else {
      throw AccountError.accountChanged
    }
    if let existing = conversations[scope] {
      await existing.prepare()
      guard notebook.account?.id == document.accountID, notebook.pendingAccount == nil else {
        throw AccountError.accountChanged
      }
      return existing
    }
    let controller = CommentConversationController(
      scope: scope, userID: services.userID, gistOwnerID: gist.owner?.id,
      knownTotal: gist.commentCount, remote: services.remote, store: store)
    conversations[scope] = controller
    await controller.prepare()
    guard notebook.account?.id == document.accountID, notebook.pendingAccount == nil else {
      throw AccountError.accountChanged
    }
    return controller
  }

  @discardableResult
  func flushDrafts() async -> Bool {
    var saved = true
    for conversation in conversations.values where conversation.isPrepared {
      if !(await conversation.flushDraft()) { saved = false }
    }
    return saved
  }
}
