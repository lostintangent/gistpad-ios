#if os(iOS)
import GistPadAppearance
import GistPadComments
import SwiftUI

@MainActor
public struct CommentsConversationActions {
    public var refresh: () async -> Void
    public var reply: ((Int64) -> Void)?
    public var edit: ((Int64) -> Void)?
    public var delete: ((Int64) -> Void)?
    public var revealPassage: ((Int64) -> Void)?
    public var areActionsEnabled = true

    public init(refresh: @escaping () async -> Void) {
        self.refresh = refresh
    }
}

public struct CommentsConversation: View {
    private let comments: [GistComment]?
    private let currentUserID: Int64?
    private let gistOwnerID: Int64?
    private let selectedRootID: Int64?
    private let selectedRootRevision: UInt64
    private let linkedRootIDs: Set<Int64>?
    private let isRefreshing: Bool
    private let failure: String?
    private let actions: CommentsConversationActions
    @State private var deletionTarget: GistComment?
    @State private var position = ScrollPosition(idType: Int64.self, edge: .top)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var threadSpacing = 16

    public init(
        comments: [GistComment]?, currentUserID: Int64?, gistOwnerID: Int64?,
        selectedRootID: Int64? = nil, selectedRootRevision: UInt64 = 0,
        linkedRootIDs: Set<Int64>? = nil,
        isRefreshing: Bool = false, failure: String? = nil,
        actions: CommentsConversationActions
    ) {
        self.comments = comments
        self.currentUserID = currentUserID
        self.gistOwnerID = gistOwnerID
        self.selectedRootID = selectedRootID
        self.selectedRootRevision = selectedRootRevision
        self.linkedRootIDs = linkedRootIDs
        self.isRefreshing = isRefreshing
        self.failure = failure
        self.actions = actions
    }

    private var threads: [GistCommentThread] {
        comments.map(GistCommentThread.build(from:)) ?? []
    }

    /// A new selection, or its thread arriving, scrolls the thread to the top once.
    private var reveal: Reveal {
        .init(
            id: selectedRootID, revision: selectedRootRevision,
            exists: threads.contains { $0.id == selectedRootID })
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if comments != nil, failure != nil || isRefreshing {
                    operationStatus
                }
                ForEach(threads) { thread in
                    CommentThreadContent(
                        thread: thread, parentLogin: nil, currentUserID: currentUserID,
                        gistOwnerID: gistOwnerID, selectedRootID: selectedRootID,
                        linkedRootIDs: linkedRootIDs, actions: actions,
                        requestDelete: { deletionTarget = $0 })
                        .padding(.horizontal, 20)
                        .padding(.vertical, threadSpacing / 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            if thread.id == selectedRootID {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(.tertiarySystemFill))
                                    .padding(.horizontal, 8)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(
                            thread.id == selectedRootID ? .isSelected : [])
                        .accessibilityIdentifier("comment-thread-\(thread.id)")
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition($position)
        .onChange(of: reveal, initial: true) { previous, reveal in
            guard reveal.exists, let id = reveal.id else { return }
            withAnimation(previous == reveal || reduceMotion ? nil : .snappy) {
                position.scrollTo(id: id, anchor: .top)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .refreshable { await actions.refresh() }
        .overlay { emptyState }
        .tint(.primary)
        .accessibilityIdentifier("comments-conversation")
        .confirmationDialog(
            String(
                localized: "Delete \(deletionTarget?.user?.login ?? String(localized: "this author", bundle: .module))’s comment from GitHub?",
                bundle: .module),
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { if !$0 { deletionTarget = nil } }),
            titleVisibility: .visible
        ) {
            if let target = deletionTarget, let delete = actions.delete {
                Button(String(localized: "Delete Comment", bundle: .module), role: .destructive) {
                    deletionTarget = nil
                    delete(target.id)
                }
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {
                deletionTarget = nil
            }
        } message: {
            if let target = deletionTarget {
                Text(
                    "“\(String(target.parsedBody.text.prefix(140)))”\n\nOnly this comment is deleted. Its replies stay in the conversation.",
                    bundle: .module)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if comments == nil {
            if let failure {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Comments couldn’t be loaded", bundle: .module).font(.headline)
                        Text(verbatim: failure)
                        retry
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            } else {
                ProgressView(String(localized: "Loading comments", bundle: .module))
                    .accessibilityIdentifier("comments-loading")
            }
        }
    }

    @ViewBuilder
    private var operationStatus: some View {
        if comments != nil {
            if let failure {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: failure)
                    retry
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .accessibilityIdentifier("comments-load-error")
            } else if isRefreshing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Updating comments", bundle: .module)
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
    }

    private var retry: some View {
        Button(String(localized: "Try Again", bundle: .module)) {
            Task { await actions.refresh() }
        }
        .buttonStyle(.glass)
        .disabled(isRefreshing)
        .accessibilityIdentifier("comments-retry")
    }

    private struct Reveal: Equatable {
        let id: Int64?
        let revision: UInt64
        let exists: Bool
    }
}

private struct CommentThreadContent: View {
    let thread: GistCommentThread
    let parentLogin: String?
    let currentUserID: Int64?
    let gistOwnerID: Int64?
    let selectedRootID: Int64?
    let linkedRootIDs: Set<Int64>?
    let actions: CommentsConversationActions
    let requestDelete: (GistComment) -> Void
    @State private var showsReplies = false
    @State private var showsFullQuote = false
    @State private var fullQuoteHeight: CGFloat = 0
    @State private var collapsedQuoteHeight: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .body) private var contentSpacing = 8
    @ScaledMetric(relativeTo: .body) private var quoteSpacing = 12

    private var comment: GistComment { thread.comment }
    private var parsed: GistCommentBody { comment.parsedBody }
    private var login: String {
        comment.user?.login ?? String(localized: "Unknown author", bundle: .module)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            commentContent
            if !thread.replies.isEmpty {
                DisclosureGroup(isExpanded: $showsReplies) {
                    ForEach(thread.replies) { reply in
                        CommentThreadContent(
                            thread: reply, parentLogin: login,
                            currentUserID: currentUserID, gistOwnerID: gistOwnerID,
                            selectedRootID: selectedRootID, linkedRootIDs: linkedRootIDs,
                            actions: actions, requestDelete: requestDelete)
                            .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : 12)
                            .padding(.top, quoteSpacing)
                    }
                    .foregroundStyle(Color(uiColor: .label))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("comment-\(comment.id)")
                } label: {
                    Text("\(thread.replies.count) replies", bundle: .module)
                        .font(.subheadline)
                        .frame(minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("comment-replies-\(comment.id)")
            }
        }
    }

    private var commentContent: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            header
            if let quote = parsed.quote, !quote.isEmpty {
                quotedPassage(quote)
            }
            Text(LocalizedStringKey(parsed.text))
                .font(.body)
                .tint(Color(uiColor: .systemBlue))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if thread.canReply, let reply = actions.reply {
                Button {
                    reply(comment.id)
                } label: {
                    Label {
                        Text("Reply", bundle: .module)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "arrowshape.turn.up.left")
                    }
                    .labelStyle(InlineActionLabelStyle())
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
                .padding(.vertical, -8)
                .disabled(!actions.areActionsEnabled)
                .accessibilityLabel(Text("Reply to \(login)", bundle: .module))
                .accessibilityIdentifier("comment-reply-\(comment.id)")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            CommentAvatar(author: comment.user)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: login)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityLabel(
                        parentLogin.map { Text("\(login), reply to \($0)", bundle: .module) }
                            ?? Text(verbatim: login))
                Text(comment.createdAt, format: .relative(presentation: .named))
                    .font(.caption)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if showsMenu {
                Menu {
                    if comment.canEdit(as: currentUserID), let edit = actions.edit {
                        Button(
                            String(localized: "Edit Comment", bundle: .module), systemImage: "pencil"
                        ) { edit(comment.id) }
                    }
                    if comment.canDelete(as: currentUserID, gistOwnerID: gistOwnerID),
                       actions.delete != nil {
                        Button(
                            String(localized: "Delete Comment…", bundle: .module),
                            systemImage: "trash", role: .destructive
                        ) { requestDelete(comment) }
                    }
                } label: {
                    Label(String(localized: "Comment actions", bundle: .module), systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(!actions.areActionsEnabled)
                .accessibilityIdentifier("comment-actions-\(comment.id)")
            }
        }
    }

    private var showsMenu: Bool {
        (comment.canEdit(as: currentUserID) && actions.edit != nil)
            || (comment.canDelete(as: currentUserID, gistOwnerID: gistOwnerID) && actions.delete != nil)
    }

    private func quotedPassage(_ quote: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(uiColor: AccentRole.text.uiColor))
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: contentSpacing) {
                HStack(alignment: .center, spacing: 8) {
                    quoteText(quote)
                        .lineLimit(showsFullQuote ? nil : 3)
                        .textSelection(.enabled)
                        .overlay(alignment: .topLeading) {
                            quoteText(quote)
                                .fixedSize(horizontal: false, vertical: true)
                                .hidden()
                                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                                    fullQuoteHeight = $0
                                }
                                .accessibilityHidden(true)
                        }
                        .background(alignment: .topLeading) {
                            quoteText(quote)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .hidden()
                                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                                    collapsedQuoteHeight = $0
                                }
                                .accessibilityHidden(true)
                        }
                    if linkedRootIDs?.contains(comment.id) == true,
                       let reveal = actions.revealPassage {
                        Button {
                            reveal(comment.id)
                        } label: {
                            Label(
                                String(localized: "Show Passage", bundle: .module),
                                systemImage: "text.viewfinder")
                                .labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                        // Keeps the 44-point target without letting it stretch the quote rule.
                        .padding(.vertical, -10)
                        .accessibilityAddTraits(
                            selectedRootID == comment.id ? .isSelected : [])
                        .accessibilityIdentifier("comment-passage-\(comment.id)")
                    }
                }
                if fullQuoteHeight > collapsedQuoteHeight + 1 / displayScale {
                    Button {
                        showsFullQuote.toggle()
                    } label: {
                        Label {
                            Text(
                                showsFullQuote
                                    ? String(localized: "Show Less", bundle: .module)
                                    : String(localized: "Show Full Quote", bundle: .module)
                            )
                            .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: showsFullQuote ? "chevron.up" : "chevron.down")
                        }
                        .labelStyle(InlineActionLabelStyle())
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
                    .padding(.vertical, -8)
                }
                if let linkedRootIDs {
                    if !linkedRootIDs.contains(comment.id) {
                        Text("Not linked in this view", bundle: .module)
                            .font(.footnote)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func quoteText(_ quote: String) -> some View {
        Text(verbatim: quote)
            .font(.subheadline)
            .tint(Color(uiColor: .systemBlue))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InlineActionLabelStyle: LabelStyle {
    @ScaledMetric(relativeTo: .subheadline) private var spacing = 5

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            configuration.icon
                .imageScale(.small)
            configuration.title
        }
    }
}

private struct CommentAvatar: View {
    let author: GistComment.Author?
    @ScaledMetric(relativeTo: .body) private var size = 28

    var body: some View {
        AsyncImage(url: author?.avatarURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(verbatim: author?.login.first.map { String($0).uppercased() } ?? "?")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .secondarySystemFill))
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}
#endif
