import Foundation
import Comments
import Sync

struct CommentServices: Sendable {
  let remote: any CommentsRemote
  let userID: Int64
}

extension GitHubSync {
  func comments(accountID: UUID) async throws -> CommentServices {
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
    return CommentServices(remote: client, userID: userID)
  }
}
