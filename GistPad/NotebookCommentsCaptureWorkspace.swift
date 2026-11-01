#if DEBUG
import GistPadComments
import GistPadPlatform
import GistPadSync
import SwiftUI

struct NotebookCommentsCaptureWorkspace: View {
  @State private var fixture = NotebookCommentsCaptureFixture()
  @State private var holdsRefresh = false

  var body: some View {
    LiveNotebookWorkspace(
      notebook: fixture.notebook, routes: NotebookRouteInbox(),
      commentsProvider: fixture.comments)
      .background {
        MarkerCaptureContrast(
          increased: ProcessInfo.processInfo.arguments.contains("--capture-increased-contrast"))
          .frame(width: 0, height: 0)
      }
      .overlay(alignment: .topLeading) {
        if ProcessInfo.processInfo.arguments.contains("--capture-controlled-comment-refresh") {
          HStack {
            Button("Hold Refresh") {
              Task {
                await fixture.remote.holdNextRefresh()
                holdsRefresh = true
              }
            }
            .accessibilityIdentifier("comments-hold-refresh")
            .accessibilityValue(holdsRefresh ? "Armed" : "Not armed")
            .disabled(holdsRefresh)
            Button("Finish Refresh") {
              Task {
                await fixture.remote.finishRefresh()
                holdsRefresh = false
              }
            }
            .accessibilityIdentifier("comments-finish-refresh")
            .disabled(!holdsRefresh)
          }
          .buttonStyle(.bordered)
          .padding(.top, 88)
          .padding(.horizontal, 8)
        }
      }
  }
}

@MainActor
final class NotebookCommentsCaptureFixture {
  let notebook: NotebookModel
  let comments: NotebookCommentProvider
  let remote: NotebookCommentsCaptureRemote
  let store: NotebookCommentsCaptureStore

  init(scenario: String? = nil) {
    let arguments = ProcessInfo.processInfo.arguments
    let requested = arguments.firstIndex(of: "--comments-fixture").flatMap { index in
      arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
    }
    let scenario = scenario ?? requested ?? "threads"
    let remote = NotebookCommentsCaptureRemote(scenario: scenario)
    let store = NotebookCommentsCaptureStore(scenario: scenario)
    let notebook = NotebookModel(
      provider: NotebookCommentsCaptureProvider(remote: remote, scenario: scenario))
    self.notebook = notebook
    self.remote = remote
    self.store = store
    comments = NotebookCommentProvider(notebook: notebook, store: store)
  }
}

enum NotebookCommentsCaptureData {
  static let title = "A place for good ideas"
  static let passage = "A good walk clears more than your head"
  static let longQuote = """
    Write something useful, then give it room to breathe. Keep a question beside an answer.
    Make space for a small surprise. A notebook can hold the shape of an unfinished idea.
    Come back with fresh eyes. Leave a little room for the next person to think
    """
    .replacingOccurrences(of: "\n", with: " ")

  static func markdown(title: String) -> String {
    """
    # \(title)

    \(passage).

    Keep the useful things close. Let the rest find their place.

    ## A little room to think

    \(longQuote).

    ## Next, something small

    - [x] Make room to write
    - [ ] Follow the thread
    - [ ] See where it goes

    """
  }

  static var comments: [GistComment] {
    [
      comment(300, body: "> \(passage)\n\n**Worth keeping.** A good place to begin.", author: 2),
      comment(301, body: "> [comment:300]\n\nI’ll bring the notebook.", author: 1),
      comment(302, body: "> [comment:301]\n\nAnd I’ll bring a question.", author: 2),
      comment(200, body: "> \(longQuote)\n\nLeave this thought open for a little longer.", author: 1),
      comment(100, body: "> A passage that is not in this file.\n\nA thought from another file.", author: 2),
    ]
  }

  static let readingIdeas = (1...24).map { "Reading idea \($0): a place to begin" }

  static func readingListMarkdown(title: String) -> String {
    "# \(title)\n\nKeep the useful things close. Let the rest find their place.\n\n"
      + readingIdeas.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
      + "\n\nLeave room for the next idea.\n"
  }

  static func longReadingMarkdown(title: String) -> String {
    let paragraph = """
      Keep the useful things close and give each thought enough room to breathe. A walk can change \
      the shape of a question before an answer arrives. Bring the notebook, notice the small details, \
      and leave a little space for the next person to think. Good ideas grow through ordinary attention.
      """
    return "# \(title)\n\n\(passage).\n\n" + (1...18).map { section in
      var text = "## Reading section \(section)\n\n"
        + Array(repeating: paragraph, count: 5).joined(separator: "\n\n") + "\n\n"
      if section.isMultiple(of: 3) {
        text += """
          | Thought | Next step | When |
          | --- | --- | --- |
          | A question worth keeping | Take a longer walk and return with a fresh perspective | Tomorrow |
          | A small observation | Share the detail with someone who will notice it too | This week |


          """
      }
      if section.isMultiple(of: 4) {
        text += """
          ```swift
          struct ReadingThought: Identifiable {
              let id: UUID
              let question: String
              let nextStep: String
          }
          ```


          """
      }
      if (section - 2).isMultiple(of: 6) {
        text += "![Two quiet shapes, reading illustration \(section)](data:image/png;base64,\(readingImage))\n\n"
      }
      return text
    }.joined()
  }

  private static let readingImage = """
    iVBORw0KGgoAAAANSUhEUgAAAeAAAADwCAIAAABXFyDtAAAEdklEQVR42u3bIVIrURCG0X+mZiXZAy4KE5FtZANZSTaQbUTEoOLYQ3TMuEgEAk9RFFTde/sc/0R64KNfw0yP9RkA2jMbAYBAAyDQAAINgEADCDQAAg2AQAMINAACDSDQAAg0AAININAACDSAQAMg0AACDYBAAyDQAAINgEADCDQAAg2AQAMINAACDSDQAAg0gEADINAACDSAQAMg0ABFLEbQpvPl9rt/eNhvTQ/GMD3Wpyn0m2PJBoGmpyLrNQg03URZrEGg6aPLSg0Crcv9UWoQaGmWaUCgpVmmQaB1eVRKDQItzTINxKve6uzzgg1aqqzSgEBLs0xDnDjUGdMAG7QYWaXBBo06mw/YoKXHKg3YoNXZxECgtQZzgzhxSEycO8AGrc6YJAi0ppgnINBqYqog0DpitmYLAq0gJgwCrR2YMwi0apg2CLReYOYg0Eqh0YBAa4T5Q7zqrQ7k798Fv19PBlXWZnc0hFqBVucuGq3LKPWXxeOnEbrM918YBUs9W59p4YmoM36Ep+yJQ52b9bq8GwJx9Ci7QauzOmOVFmhQZzRaoK3P6oxGC7Q6o85otECjzqDRNQJtfQYEWp2xPmOJFmjUGco0erY+Awg0ALUDbX2O+wZx5RBodQYQaACBtj4T9w3iyiHQAAg0gEDHfQNAoAEE2voMINAAjBJo6zMg0AAINIBAx30DQKABEGgAgY77BoBAAwg0AAINwHCBdoAGBBoAgQZAoAEEGoBKgfYbQkCgARBoAAQaQKABEGgAgY4/4QAQaACBBkCgARBoAIEGQKABBBoAgQZAoAEEGgCBBhBoAAQaQKABEGgABBpAoAEQaACBbtxhv/XkAIEGQKABEGgAgQZAoAEEOv6QA0CgAQQaAIEGQKABBDp+Twgg0AACDYBAAzBUoJ2hAYEGQKABGCPQrhyAQAMg0ACMEWhXDkCgARBoSzQg0EYAINCWaAAbNIBAAyDQceXo19vHiyHw3za7o0ADINCWaECgNZq4chD3DYEGoGygLdGAQENcOYj7hkBbojUa6tR58A1aowGBBks01meBtkRrNNSoc4kNWqM1GnUWaNBo1FmgLdEajToXMD3WZ5GPer7cfGU3+7Pzfj2ZBtJc98Rhj275iVT7xkOdf2Lx1Gnt2882TfEup+CJIw4dvf2HRql1ubhygdZo5yaIG7Q6YP4g0Bph8iDQSoGZg0DrhWmDQKsG5gwCrR0mDAi0gpgtCLSOYKog0GpiniDQmoJJQrzqHa+DSzNgg1YZcwOB1hoTA+LEEecOaQYbtPpgPmCDtkpLM9igjUCPTANs0FZpaQYEWqalGeLEYZH0eQEbtFVamkGgUWpdBoGWaWkGBFqmpRkEmv5Krcsg0Eqty4BAi7Uog0DTeK8VGQSaJpItxyDQAMSr3gACDYBAAyDQAAINgEADCDQAAg2AQAMINAACDSDQAAg0gEADINAACDSAQAMg0AACDYBAAyDQAAINgEADCDQAAg0g0AAINAACDSDQAAg0gEADINAACDRAXz4BB8K0FqdZwmsAAAAASUVORK5CYII=
    """

  static var readingListComments: [GistComment] {
    readingIdeas.enumerated().map { index, quote in
      comment(
        Int64(10_000 + (index * 7) % readingIdeas.count),
        body: "> \(quote)\n\nReading thought \(index + 1). Keep this one close.", author: 1,
        createdAt: Date(timeIntervalSince1970: 1_792_886_400 + Double(index)))
    } + [
      comment(
        10_999, body: "> A passage removed from this reading list.\n\nAn older thought remains.",
        author: 2, createdAt: Date(timeIntervalSince1970: 1_792_886_412.5)),
      comment(
        20_050, body: "> \(readingIdeas[5])\n\nAnother thought about reading idea 6.",
        author: 2, createdAt: Date(timeIntervalSince1970: 1_792_886_405.5)),
      comment(
        20_051, body: "> Reading idea 6\n\nA narrower thought about reading idea 6.",
        author: 2, createdAt: Date(timeIntervalSince1970: 1_792_886_405.6)),
    ]
  }

  static func comment(
    _ id: Int64, body: String, author: Int64, createdAt: Date? = nil
  ) -> GistComment {
    let date = createdAt ?? Date(timeIntervalSince1970: 1_792_886_400 + Double(id))
    return .init(
      id: id, body: body, user: .init(id: author, login: author == 1 ? "octavia" : "mira"),
      createdAt: date, updatedAt: date)
  }
}

actor NotebookCommentsCaptureStore: CommentConversationStore {
  private var deletedScopes: Set<CommentConversationScope> = []
  private var archives: [CommentConversationScope: CommentDraftArchive] = [:]
  private var failuresRemaining: Int
  private let failsReads: Bool

  init(scenario: String) {
    failuresRemaining = scenario == "draft-failure" ? 2 : 0
    failsReads = scenario == "store-unavailable"
  }

  func loadDrafts(scope: CommentConversationScope) throws -> CommentDraftArchive? {
    if failsReads { throw CommentStoreFailure.unavailable }
    return archives[scope]
  }

  func saveDrafts(_ archive: CommentDraftArchive) throws {
    guard !deletedScopes.contains(archive.scope) else { throw CommentStoreFailure.unavailable }
    if failuresRemaining > 0, archive.drafts.contains(where: { !$0.text.isEmpty }) {
      failuresRemaining -= 1
      throw CommentStoreFailure.unavailable
    }
    if let previous = archives[archive.scope], previous.revision > archive.revision {
      throw CommentStoreFailure.staleWrite
    }
    archives[archive.scope] = archive
  }

  func removeDrafts(scope: CommentConversationScope) {
    deletedScopes.insert(scope)
    archives[scope] = nil
  }
}

actor NotebookCommentsCaptureRemote: CommentConversationRemote {
  private let scenario: String
  private var records: [String: [GistComment]] = [:]
  private var nextID: Int64 = 1_000
  private(set) var createdBodies: [String] = []
  private(set) var editedBodies: [String] = []
  private(set) var deletedIDs: [Int64] = []
  private(set) var listRequests = 0
  private var holdsNextRefresh = false
  private var pendingRefresh: CheckedContinuation<Void, Never>?

  init(scenario: String) { self.scenario = scenario }

  func holdNextRefresh() { holdsNextRefresh = true }

  func finishRefresh() {
    holdsNextRefresh = false
    pendingRefresh?.resume()
    pendingRefresh = nil
  }

  func listComments(gistID: String) async throws(CommentRemoteFailure) -> [GistComment] {
    listRequests += 1
    if scenario == "late-count", listRequests == 1 {
      do { try await Task.sleep(for: .seconds(3)) }
      catch { throw .network }
    }
    if holdsNextRefresh {
      holdsNextRefresh = false
      await withCheckedContinuation { pendingRefresh = $0 }
    }
    if scenario == "loading", listRequests == 1 {
      do { try await Task.sleep(for: .seconds(6)) }
      catch { throw .network }
    }
    if scenario == "offline" { throw .network }
    return comments(gistID)
  }

  func comment(gistID: String, commentID: Int64) throws(CommentRemoteFailure) -> GistComment {
    guard let comment = comments(gistID).first(where: { $0.id == commentID }) else { throw .notFound }
    return comment
  }

  func createComment(gistID: String, body: String) async throws(CommentRemoteFailure) -> GistComment {
    if scenario == "rejected" { throw .forbidden }
    if ProcessInfo.processInfo.arguments.contains("--capture-hold-comment-post") {
      do { try await Task.sleep(for: .seconds(8)) } catch { throw .network }
    }
    let created = NotebookCommentsCaptureData.comment(nextID, body: body, author: 1, createdAt: .now)
    nextID += 1
    records[gistID] = comments(gistID) + [created]
    createdBodies.append(body)
    if scenario == "uncertain" { throw .network }
    return created
  }

  func updateComment(
    gistID: String, commentID: Int64, body: String
  ) throws(CommentRemoteFailure) -> GistComment {
    guard let previous = comments(gistID).first(where: { $0.id == commentID }) else { throw .notFound }
    let updated = GistComment(
      id: previous.id, body: body, user: previous.user, createdAt: previous.createdAt, updatedAt: .now)
    records[gistID] = comments(gistID).map { $0.id == commentID ? updated : $0 }
    editedBodies.append(body)
    return updated
  }

  func deleteComment(gistID: String, commentID: Int64) throws(CommentRemoteFailure) {
    guard comments(gistID).contains(where: { $0.id == commentID }) else { throw .notFound }
    records[gistID] = comments(gistID).filter { $0.id != commentID }
    deletedIDs.append(commentID)
  }

  private func comments(_ gistID: String) -> [GistComment] {
    records[gistID] ?? (scenario == "empty" || gistID == "quiet"
      ? [] : scenario == "reading-list"
        ? NotebookCommentsCaptureData.readingListComments : NotebookCommentsCaptureData.comments)
  }
}

actor NotebookCommentsCaptureProvider: NotebookProviding, NotebookCommentProviding, NotebookPhotoProviding {
  private let account = NotebookAccount(
    id: UUID(), login: "octavia", githubUserID: 1,
    preferences: .init(isAutoSaveEnabled: false, accentColor: nil))
  private let remote: NotebookCommentsCaptureRemote
  private let scenario: String
  private var cache: CachedLibrarySnapshot?
  private var store: DraftStore?

  init(remote: NotebookCommentsCaptureRemote, scenario: String) {
    self.remote = remote
    self.scenario = scenario
  }

  func cachedAccount() -> NotebookAccount? { account }
  func signIn() -> NotebookAccount { account }
  func refreshAccount() -> NotebookAccount { account }
  func gists(accountID: UUID) throws -> [Gist] { try fixtureGists().filter { $0.id != "shared" } }
  func starredGists(accountID: UUID) throws -> [Gist] { try fixtureGists().filter { $0.id == "shared" } }
  func gist(id: String, accountID: UUID) throws -> Gist {
    guard let gist = try fixtureGists().first(where: { $0.id == id }) else {
      throw GitHubClientError.missingFile
    }
    return gist
  }

  func content(gist: Gist, filename: String, accountID: UUID) throws -> String {
    guard let text = gist.files[filename]?.content else { throw GitHubClientError.missingFile }
    return text
  }

  func commentServices(accountID: UUID) throws -> NotebookCommentServices {
    guard accountID == account.id else { throw AccountError.accountChanged }
    return .init(remote: remote, userID: 1)
  }

  func photoServices(accountID: UUID) async throws -> NotebookPhotoServices {
    let store = try draftStore()
    let storage = try ImageStorageClient(publishableKey: "sb_publishable_fixture") {
      throw CaptureError.unsupported
    }
    return .init(
      store: store,
      uploads: ImageUploadCoordinator(accountID: accountID, store: store, storage: storage))
  }

  func openDraft(for document: NotebookDocument) async throws -> DraftSnapshot {
    let store = try draftStore()
    if let draft = document.draft { return try await store.draft(id: draft.id, accountID: account.id) }
    guard let gist = document.gist else { throw GitHubClientError.missingFile }
    return try await store.openDraft(
      accountID: account.id, githubUserID: 1, gistID: gist.id, filename: document.filename,
      description: gist.description ?? "", content: document.text, revision: gist.revision)
  }

  func persist(
    draftID: UUID, accountID: UUID, text: String, generation: UInt64
  ) async throws -> DraftSnapshot {
    try await draftStore().persist(
      id: draftID, accountID: accountID, text: text, generation: generation)
  }

  func publish(
    draftID: UUID, accountID: UUID, reason: PublishReason, expectedGeneration: UInt64?,
    shouldPublish: @escaping @Sendable () async -> Bool
  ) throws -> DraftSnapshot { throw CaptureError.unsupported }

  func localState(accountID: UUID) async throws -> NotebookLocalState {
    .init(library: cache, drafts: try await store?.drafts(accountID: accountID) ?? [])
  }

  func cacheLibrary(owned: [Gist], starred: [Gist], account: NotebookAccount) {
    cache = .init(
      accountID: account.id, owned: owned, starred: starred, preferences: account.preferences)
  }

  func createDraft(accountID: UUID) async throws -> DraftSnapshot {
    try await draftStore().createGistDraft(accountID: accountID, githubUserID: 1)
  }

  func discardBlankDraft(_ draft: DraftSnapshot) async throws -> Bool {
    try await draftStore().discardBlankDraft(
      id: draft.id, accountID: draft.accountID, expectedGeneration: draft.generation)
  }

  func today(accountID: UUID, target: DailyNoteTarget) throws -> TodayNote { throw CaptureError.unsupported }
  func perform(_ action: NotebookAction, accountID: UUID) async throws -> NotebookActionResult {
    guard case .inspectRemote(let id, let generation) = action else {
      throw CaptureError.unsupported
    }
    let store = try draftStore()
    let current = try await store.draft(id: id, accountID: accountID)
    guard let gistID = current.gistID else { return .review(current) }
    let gist = try gist(id: gistID, accountID: accountID)
    return .review(
      try await store.inspectRemoteChange(
        id: id, accountID: accountID, expectedGeneration: generation,
        remote: gist.files[current.filename]?.content, revision: gist.revision))
  }

  private func draftStore() throws -> DraftStore {
    if let store { return store }
    let created = try DraftStore.open(inMemory: true)
    store = created
    return created
  }

  private func fixtureGists() throws -> [Gist] {
    let payload = [
      ("ideas", NotebookCommentsCaptureData.title),
      ("quiet", "A little quiet"), ("shared", "A friend’s field guide"),
    ].map { id, title -> [String: Any] in
      var payload: [String: Any] = [
        "id": id, "description": title, "public": false,
        "comments": id == "quiet" || scenario == "empty" ? 0
          : scenario == "reading-list" ? NotebookCommentsCaptureData.readingListComments.count
          : NotebookCommentsCaptureData.comments.count,
        "updated_at": "2026-10-24T00:00:00Z", "created_at": "2026-10-23T00:00:00Z",
        "owner": ["id": id == "shared" ? 9 : 1, "login": id == "shared" ? "a-friend" : account.login],
        "files": [
          "README.md": [
            "filename": "README.md", "language": "Markdown",
            "content": scenario == "reading-list"
              ? NotebookCommentsCaptureData.readingListMarkdown(title: title)
              : scenario == "long-reading" ? NotebookCommentsCaptureData.longReadingMarkdown(title: title)
              : NotebookCommentsCaptureData.markdown(title: title),
          ],
          "Appendix.md": [
            "filename": "Appendix.md", "language": "Markdown",
            "content": "# \(title)\n\nAn appendix with a different passage.",
          ],
        ],
        "history": [["version": "synthetic-comments-revision"]],
      ]
      if scenario == "late-count" { payload.removeValue(forKey: "comments") }
      return payload
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([Gist].self, from: JSONSerialization.data(withJSONObject: payload))
  }

  private enum CaptureError: LocalizedError {
    case unsupported
    var errorDescription: String? { "This synthetic fixture does not perform that account action." }
  }
}
#endif
