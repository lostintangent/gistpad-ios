import GistPadComments
import GistPadInterface
import SwiftUI

struct NotebookCommentsInspector: View {
  @Bindable var conversation: CommentConversationController
  let selectedRootID: Int64?
  var threadRevealRevision: UInt64 = 0
  let linkedRootIDs: Set<Int64>?
  var presentationProblem: String?
  @Binding var focusRequest: UInt64
  let close: () async -> Void
  let revealPassage: (Int64) -> Void
  let didFocus: () -> Void
  @State private var isClosing = false
  @State private var linkFailure: String?

  var body: some View {
    NavigationStack {
      CommentsConversation(
        comments: conversation.comments, currentUserID: conversation.userID,
        gistOwnerID: conversation.gistOwnerID, selectedRootID: selectedRootID,
        selectedRootRevision: threadRevealRevision,
        linkedRootIDs: linkedRootIDs, isRefreshing: conversation.isRefreshing,
        failure: conversation.loadFailure?.interfaceDescription ?? presentationProblem, actions: actions)
        .safeAreaBar(edge: .bottom, spacing: 0) {
          composer
        }
        .navigationTitle("Comments")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(role: .close) {
              Task {
                isClosing = true
                defer { isClosing = false }
                await close()
              }
            }
            .disabled(isClosing)
            .accessibilityIdentifier("comments-close")
          }
          ToolbarItem(placement: .primaryAction) {
            Button("Refresh Comments", systemImage: "arrow.clockwise") {
              Task { await conversation.refresh() }
            }
            .disabled(conversation.isRefreshing || conversation.mutation == .working)
            .accessibilityIdentifier("comments-refresh")
          }
        }
    }
    .interactiveDismissDisabled(
      conversation.draftSaveState != .saved || conversation.mutation == .working)
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
    actions.areActionsEnabled =
      conversation.composer.canEdit && conversation.pendingMutation == nil
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
    VStack(alignment: .leading, spacing: 0) {
      if conversation.mutation == .needsRefresh {
        recovery(
          message: String(localized: "Refresh comments to check the previous change."),
          action: String(localized: "Refresh Comments")
        ) { await conversation.refresh() }
      } else if conversation.mutation == .localCompletionFailed {
        recovery(
          message: String(localized: "Saved on GitHub. Finish saving its local record."),
          action: String(localized: "Finish Saving")
        ) { await conversation.retryLocalCompletion() }
      }
      if conversation.composer.problem == .commentChanged,
        case .edit(let id, _) = conversation.activeDraft.target {
        recovery(
          message: String(localized: "Keep your text and use the latest version as the edit’s starting point."),
          action: String(localized: "Use Latest Version")
        ) { conversation.restartEditing(id) }
      }
      CommentsComposer(
        text: Binding(get: { conversation.activeDraft.text }, set: conversation.updateText),
        context: composerContext, canPost: conversation.composer.canPost,
        isEditable: conversation.composer.canEdit, isPosting: conversation.mutation == .working,
        failure: composerProblem,
        draftSaveFailure: conversation.draftSaveState == .failed
          && conversation.mutation != .localCompletionFailed
          ? CommentConversationProblem.localStorage.interfaceDescription : nil,
        focusRequest: focusRequest,
        post: { Task { await conversation.post() } },
        removeContext: {
          if case .edit = conversation.activeDraft.target {
            conversation.beginComment()
            focusRequest = 0
          } else {
            conversation.removeComposerContext()
            focusComposer()
          }
        },
        retryDraftSave: {
          Task {
            await conversation.prepare()
            await conversation.flushDraft()
          }
        },
        didFocus: didFocus)
    }
  }

  private var composerContext: CommentsComposerContext {
    switch conversation.activeDraft.target {
    case .root:
      .root
    case .quote(let quote):
      .quote(text: quote.text, filename: quote.filename)
    case .reply(let id):
      .reply(author: conversation.comments?.first { $0.id == id }?.user?.login)
    case .edit:
      .editing
    }
  }

  private var composerProblem: String? {
    guard conversation.draftSaveState != .failed else { return nil }
    if let problem = conversation.composer.problem, problem != .localStorage {
      return problem.interfaceDescription
    }
    if case .failed(let problem) = conversation.mutation {
      return problem.interfaceDescription
    }
    return nil
  }

  private func recovery(
    message: String, action: String, perform: @escaping () async -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: message)
      Button(action) { Task { await perform() } }
        .buttonStyle(.glass)
        .tint(.primary)
    }
    .font(.footnote)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 20)
    .padding(.vertical, 8)
  }

  private func focusComposer() {
    guard conversation.composer.canEdit, conversation.composer.problem == nil else { return }
    didFocus()
    focusRequest &+= 1
  }
}
