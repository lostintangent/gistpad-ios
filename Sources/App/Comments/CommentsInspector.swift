import Comments
import Interface
import Notebook
import SwiftUI

struct CommentsInspector: View {
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

extension View {
  /// Comments for the open gist: an inspector beside the file on a wide display, a sheet on iPhone.
  func commentsInspector(
    _ comments: CommentsPresentation, active: FileSession?,
    columnVisibility: Binding<NavigationSplitViewVisibility>
  ) -> some View {
    modifier(CommentsInspectorHost(
      comments: comments, active: active, columnVisibility: columnVisibility))
  }
}

private struct CommentsInspectorHost: ViewModifier {
  @Bindable var comments: CommentsPresentation
  let active: FileSession?
  @Binding var columnVisibility: NavigationSplitViewVisibility
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private struct CommentCount: Equatable {
    let scope: CommentsPresentation.Scope
    let total: Int
  }

  private var commentCount: CommentCount? {
    guard let scope = comments.scope, let total = comments.conversation?.comments?.count else { return nil }
    return .init(scope: scope, total: total)
  }

  func body(content: Content) -> some View {
    content
      .toolbar(removing: comments.isPresented && horizontalSizeClass == .regular ? .sidebarToggle : nil)
      .inspector(isPresented: $comments.isPresented) {
        panel
          .inspectorColumnWidth(min: 280, ideal: 320, max: 360)
          .presentationDetents(
            dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large],
            selection: Binding(
              get: { dynamicTypeSize.isAccessibilitySize ? .large : comments.detent },
              set: { comments.detent = $0 }))
          .presentationDragIndicator(.visible)
          .presentationBackgroundInteraction(.enabled(upThrough: .medium))
          .onDisappear {
            if !comments.isPresented, let previous = comments.sidebarBeforeOpening {
              comments.sidebarBeforeOpening = nil
              columnVisibility = previous
            }
            comments.didDismiss()
          }
      }
      .onChange(of: comments.isPresented) { _, presented in
        if presented, horizontalSizeClass == .regular {
          if comments.sidebarBeforeOpening == nil {
            comments.sidebarBeforeOpening = columnVisibility
          }
          columnVisibility = .detailOnly
        } else if !presented, comments.sidebarBeforeOpening != nil {
          // Dismiss any temporary overlay before restoring the pinned column at native completion.
          columnVisibility = .detailOnly
        }
      }
      .onChange(of: horizontalSizeClass) { _, sizeClass in
        if comments.isPresented, sizeClass == .regular {
          if comments.sidebarBeforeOpening == nil {
            comments.sidebarBeforeOpening = columnVisibility
          }
          columnVisibility = .detailOnly
        }
      }
      .onChange(of: commentCount, initial: true) { _, count in
        if let count {
          comments.library.recordCommentCount(
            accountID: count.scope.accountID, gistID: count.scope.gistID, total: count.total)
        }
      }
      .confirmationDialog(
        String(localized: "Choose Comment"),
        isPresented: choicePresented(inInspector: false),
        titleVisibility: .visible
      ) {
        choices
      }
  }

  @ViewBuilder
  private var panel: some View {
    Group {
      if let conversation = comments.conversation {
        CommentsInspector(
          conversation: conversation, selectedRootID: comments.selectedRootID,
          threadRevealRevision: comments.threadRevealRevision,
          linkedRootIDs: comments.fileMode == .edit
            ? comments.sourceLinkedIDs : comments.previewLinkedIDs,
          isComposerFocused: $comments.isComposerFocused,
          close: { comments.hide() },
          revealPassage: comments.revealPassage,
          didFocus: { comments.detent = .large })
      } else {
        NavigationStack {
          Group {
            if let failure = comments.preparationFailure {
              VStack(alignment: .leading, spacing: 12) {
                Text("Comments couldn’t be opened").font(.headline)
                Text(verbatim: failure)
                Button("Try Again") { comments.retryOpening() }
                  .buttonStyle(.glass)
              }
              .padding(20)
            } else {
              ProgressView("Opening comments")
            }
          }
          .navigationTitle("Comments")
          .navigationSubtitle("All files in this gist")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button(role: .close) { comments.hide() }
            }
          }
        }
      }
    }
    .onChange(of: dynamicTypeSize, initial: true) { _, size in
      if size.isAccessibilitySize { comments.detent = .large }
    }
    .confirmationDialog(
      String(localized: "Choose Comment"),
      isPresented: choicePresented(inInspector: true),
      titleVisibility: .visible
    ) {
      choices
    }
  }

  private func choicePresented(inInspector: Bool) -> Binding<Bool> {
    Binding(
      get: { comments.isPresented == inInspector && !comments.overlappingIDs.isEmpty },
      set: { presented in
        if !presented, comments.isPresented == inInspector { comments.overlappingIDs = [] }
      })
  }

  @ViewBuilder
  private var choices: some View {
    ForEach(comments.overlappingIDs, id: \.self) { id in
      if let thread = comments.conversation?.threads.first(where: { $0.id == id }),
        let active {
        let author = thread.comment.user?.login ?? String(localized: "Unknown author")
        let excerpt = String(thread.comment.parsedBody.text.prefix(80))
        Button("\(author): \(excerpt)") {
          comments.overlappingIDs = []
          comments.open(for: active, origin: comments.fileMode, rootID: id)
        }
      }
    }
    Button("Cancel", role: .cancel) { comments.overlappingIDs = [] }
  }
}
