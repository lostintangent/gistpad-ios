import GistPadComments
import GistPadInterface
import SwiftUI

struct NotebookCommentsInspector: View {
  @Bindable var conversation: CommentsModel
  let selectedRootID: Int64?
  var threadRevealRevision: UInt64 = 0
  let linkedRootIDs: Set<Int64>?
  @Binding var isComposerFocused: Bool
  let close: () -> Void
  let revealPassage: (Int64) -> Void
  let didFocus: () -> Void
  @State private var linkFailure: String?

  var body: some View {
    NavigationStack {
      CommentsConversation(
        comments: conversation.comments, currentUserID: conversation.userID,
        gistOwnerID: conversation.gistOwnerID, selectedRootID: selectedRootID,
        selectedRootRevision: threadRevealRevision,
        linkedRootIDs: linkedRootIDs, isRefreshing: conversation.isRefreshing,
        failure: conversation.failure == .load ? conversation.failure?.interfaceDescription : nil,
        actions: actions)
        .safeAreaBar(edge: .bottom, spacing: 0) {
          composer
        }
        .navigationTitle("Comments")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(role: .close, action: close)
              .accessibilityIdentifier("comments-close")
          }
        }
    }
    .environment(\.openURL, OpenURLAction { url in
      guard url.scheme == "https" || url.scheme == "http" else {
        linkFailure = String(localized: "Only web links can be opened from a comment.")
        return .handled
      }
      return .systemAction
    })
    .alert(
      String(localized: "Couldn’t Open Link"),
      isPresented: Binding(
        get: { linkFailure != nil }, set: { if !$0 { linkFailure = nil } })
    ) {
      Button("OK", role: .cancel) { linkFailure = nil }
    } message: {
      Text(verbatim: linkFailure ?? "")
    }
    .accessibilityIdentifier("comments-inspector")
  }

  private var actions: CommentsConversationActions {
    var actions = CommentsConversationActions(refresh: { await conversation.refresh() })
    actions.areActionsEnabled = !conversation.isPosting
    actions.reply = { id in
      conversation.beginReply(to: id)
      focusComposer()
    }
    actions.edit = { id in
      conversation.beginEditing(id)
      focusComposer()
    }
    actions.delete = { id in Task { await conversation.delete(id) } }
    actions.revealPassage = revealPassage
    return actions
  }

  private var composer: some View {
    CommentsComposer(
      text: $conversation.draft, context: composerContext, canPost: conversation.canPost,
      isPosting: conversation.isPosting,
      failure: conversation.failure == .load ? nil : conversation.failure?.interfaceDescription,
      isFocused: $isComposerFocused,
      post: { Task { await conversation.post() } },
      removeContext: {
        if case .edit = conversation.target { isComposerFocused = false } else { focusComposer() }
        conversation.removeContext()
      },
      didFocus: didFocus)
  }

  private var composerContext: CommentsComposerContext {
    switch conversation.target {
    case .root:
      .root
    case .quote(let text, let filename):
      .quote(text: text, filename: filename)
    case .reply(let id):
      .reply(author: conversation.comments?.first { $0.id == id }?.user?.login)
    case .edit:
      .editing
    }
  }

  private func focusComposer() {
    didFocus()
    isComposerFocused = true
  }
}
