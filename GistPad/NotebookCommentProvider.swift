import Foundation
import GistPadComments
import GistPadSync

struct NotebookCommentServices: Sendable {
  let remote: any CommentsRemote
  let userID: Int64
}

extension LiveNotebookProvider {
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
    return NotebookCommentServices(remote: client, userID: userID)
  }
}
