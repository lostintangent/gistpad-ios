import Appearance
import Comments
import SwiftUI

struct CommentsConversation: View {
    let comments: CommentsPresentation
    let model: CommentsModel
    @State private var deletionTarget: GistComment?
    @State private var position = ScrollPosition(idType: Int64.self, edge: .top)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var threadSpacing = 16

    private var failure: String? {
        model.failure == .load ? model.failure?.interfaceDescription : nil
    }

    /// A new selection, or its thread arriving, scrolls the thread to the top once.
    private func reveal(in threads: [GistCommentThread]) -> Reveal {
        .init(
            id: comments.selectedThreadID, revision: comments.revealRevision,
            exists: threads.contains { $0.id == comments.selectedThreadID })
    }

    var body: some View {
        let threads = model.threads
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.comments != nil, let failure {
                    refreshFailure(failure)
                }
                ForEach(threads) { thread in
                    CommentThreadContent(
                        comments: comments, model: model, thread: thread, parentLogin: nil,
                        requestDelete: { deletionTarget = $0 })
                        .padding(.horizontal, 20)
                        .padding(.vertical, threadSpacing / 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            if thread.id == comments.selectedThreadID {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(.tertiarySystemFill))
                                    .padding(.horizontal, 8)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(
                            thread.id == comments.selectedThreadID ? .isSelected : [])
                        .accessibilityIdentifier("comment-thread-\(thread.id)")
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition($position)
        .onChange(of: reveal(in: threads), initial: true) { previous, reveal in
            guard reveal.exists, let id = reveal.id else { return }
            withAnimation(previous == reveal || reduceMotion ? nil : .snappy) {
                position.scrollTo(id: id, anchor: .top)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .refreshable { await model.refresh() }
        .overlay { emptyState }
        .tint(.primary)
        .accessibilityIdentifier("comments-conversation")
        .confirmationDialog(
            "Delete \(deletionTarget?.user?.login ?? String(localized: "this author"))’s comment from GitHub?",
            item: $deletionTarget,
            titleVisibility: .visible
        ) { target in
            Button("Delete Comment", role: .destructive) {
                Task { await model.delete(target.id) }
            }
        } message: { target in
            Text(
                "“\(String(target.parsedBody.text.prefix(140)))”\n\nOnly this comment is deleted. Its replies stay in the conversation.")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.comments == nil {
            if let failure {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Comments couldn’t be loaded").font(.headline)
                        Text(verbatim: failure)
                        retry
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            } else {
                ProgressView("Loading comments")
                    .accessibilityIdentifier("comments-loading")
            }
        }
    }

    private func refreshFailure(_ failure: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: failure)
            retry
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .accessibilityIdentifier("comments-load-error")
    }

    private var retry: some View {
        Button("Try Again") {
            Task { await model.refresh() }
        }
        .buttonStyle(.glass)
        .disabled(model.isRefreshing)
        .accessibilityIdentifier("comments-retry")
    }

    private struct Reveal: Equatable {
        let id: Int64?
        let revision: UInt64
        let exists: Bool
    }
}

private struct CommentThreadContent: View {
    let comments: CommentsPresentation
    let model: CommentsModel
    let thread: GistCommentThread
    let parentLogin: String?
    let requestDelete: (GistComment) -> Void
    @State private var showsReplies = false
    @State private var showsFullQuote = false
    @State private var quoteIsLong = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var contentSpacing = 8
    @ScaledMetric(relativeTo: .body) private var quoteSpacing = 12
    @ScaledMetric(relativeTo: .body) private var avatarSize = 28

    private var comment: GistComment { thread.comment }
    private var parsed: GistCommentBody { comment.parsedBody }
    private var login: String {
        comment.user?.login ?? String(localized: "Unknown author")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            commentContent
            if !thread.replies.isEmpty {
                DisclosureGroup(isExpanded: $showsReplies) {
                    ForEach(thread.replies) { reply in
                        CommentThreadContent(
                            comments: comments, model: model, thread: reply, parentLogin: login,
                            requestDelete: requestDelete)
                            .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : 12)
                            .padding(.top, quoteSpacing)
                    }
                    .foregroundStyle(Color(uiColor: .label))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("comment-\(comment.id)")
                } label: {
                    Text("\(thread.replies.count) replies")
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
            if thread.canReply {
                Button {
                    model.beginReply(to: comment.id)
                    comments.focusComposer()
                } label: {
                    Label {
                        Text("Reply")
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
                .disabled(model.isPosting)
                .accessibilityLabel(Text("Reply to \(login)"))
                .accessibilityIdentifier("comment-reply-\(comment.id)")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            AsyncImage(url: comment.user?.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Text(verbatim: comment.user?.login.first.map { String($0).uppercased() } ?? "?")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .secondarySystemFill))
            }
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(.circle)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: login)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityLabel(
                        parentLogin.map { Text("\(login), reply to \($0)") }
                            ?? Text(verbatim: login))
                Text(comment.createdAt, format: .relative(presentation: .named))
                    .font(.caption)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if canEdit || canDelete {
                Menu {
                    if canEdit {
                        Button("Edit Comment", systemImage: "pencil") {
                            model.beginEditing(comment.id)
                            comments.focusComposer()
                        }
                    }
                    if canDelete {
                        Button("Delete Comment", systemImage: "trash", role: .destructive) {
                            requestDelete(comment)
                        }
                    }
                } label: {
                    Label("Comment actions", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(model.isPosting)
                .accessibilityIdentifier("comment-actions-\(comment.id)")
            }
        }
    }

    private var canEdit: Bool { comment.canEdit(as: model.userID) }

    private var canDelete: Bool {
        comment.canDelete(as: model.userID, gistOwnerID: model.gistOwnerID)
    }

    private func quotedPassage(_ quote: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(uiColor: .accentText))
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: contentSpacing) {
                HStack(alignment: .center, spacing: 8) {
                    quoteText(quote)
                        .lineLimit(showsFullQuote ? nil : 3)
                        .textSelection(.enabled)
                        .onPreferenceChange(Text.LayoutKey.self) { layouts in
                            guard let layout = layouts.first?.layout else { return }
                            quoteIsLong = showsFullQuote ? layout.count > 3 : layout.isTruncated
                        }
                    if comments.linkedThreadIDs?.contains(comment.id) == true {
                        Button {
                            comments.revealPassage(comment.id)
                        } label: {
                            Label("Show in File", systemImage: "text.viewfinder")
                                .labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                        // Keeps the 44-point target without letting it stretch the quote rule.
                        .padding(.vertical, -10)
                        .accessibilityAddTraits(
                            comments.selectedThreadID == comment.id ? .isSelected : [])
                        .accessibilityIdentifier("comment-passage-\(comment.id)")
                    }
                }
                if quoteIsLong {
                    Button {
                        showsFullQuote.toggle()
                    } label: {
                        Label {
                            Text(showsFullQuote ? "Show Less" : "Show Full Quote")
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
                if comments.linkedThreadIDs?.contains(comment.id) == false {
                    Text("Not found in this file")
                        .font(.footnote)
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
