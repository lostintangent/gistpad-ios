import Comments
import Model
import SwiftUI

struct CommentsInspector: View {
    let comments: CommentsPresentation
    @State private var linkFailure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let model = comments.model {
                    CommentsConversation(comments: comments, model: model)
                        .safeAreaBar(edge: .bottom, spacing: 0) {
                            CommentsComposer(comments: comments, model: model)
                        }
                } else {
                    ProgressView("Loading comments")
                }
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { comments.hide() }
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
        .alert("Couldn’t Open Link", item: $linkFailure) { _ in
        } message: { failure in
            Text(verbatim: failure)
        }
        .accessibilityIdentifier("comments-inspector")
    }
}

extension View {
    /// Comments for the open gist: an inspector beside the file on a wide display, a sheet on iPhone.
    func commentsInspector(
        _ comments: CommentsPresentation, active: GistFileEditor?,
        columnVisibility: Binding<NavigationSplitViewVisibility>
    ) -> some View {
        modifier(CommentsInspectorHost(
            comments: comments, active: active, columnVisibility: columnVisibility))
    }
}

private struct CommentsInspectorHost: ViewModifier {
    @Bindable var comments: CommentsPresentation
    let active: GistFileEditor?
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @State private var sidebarBeforeOpening: NavigationSplitViewVisibility?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private struct CommentCount: Equatable {
        let scope: CommentsPresentation.Scope
        let total: Int
    }

    private var commentCount: CommentCount? {
        guard let scope = comments.scope, let total = comments.model?.comments?.count else { return nil }
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
                        if !comments.isPresented, let previous = sidebarBeforeOpening {
                            sidebarBeforeOpening = nil
                            columnVisibility = previous
                        }
                        comments.didDismiss()
                    }
            }
            .onChange(of: comments.isPresented) { _, presented in
                if presented, horizontalSizeClass == .regular {
                    hideSidebar()
                } else if !presented, sidebarBeforeOpening != nil {
                    // Dismiss any temporary overlay before restoring the pinned column at native completion.
                    columnVisibility = .detailOnly
                }
            }
            .onChange(of: horizontalSizeClass) { _, sizeClass in
                if comments.isPresented, sizeClass == .regular { hideSidebar() }
            }
            .onChange(of: commentCount, initial: true) { _, count in
                if let count {
                    comments.app.recordCommentCount(
                        accountID: count.scope.accountID, gistID: count.scope.gistID, total: count.total)
                }
            }
            .confirmationDialog(
                "Choose Comment",
                isPresented: choicePresented(inInspector: false),
                titleVisibility: .visible
            ) {
                choices
            }
    }

    private func hideSidebar() {
        if sidebarBeforeOpening == nil { sidebarBeforeOpening = columnVisibility }
        columnVisibility = .detailOnly
    }

    private var panel: some View {
        CommentsInspector(comments: comments)
            .onChange(of: dynamicTypeSize, initial: true) { _, size in
                if size.isAccessibilitySize { comments.detent = .large }
            }
            .confirmationDialog(
                "Choose Comment",
                isPresented: choicePresented(inInspector: true),
                titleVisibility: .visible
            ) {
                choices
            }
    }

    private func choicePresented(inInspector: Bool) -> Binding<Bool> {
        Binding(
            get: { comments.isPresented == inInspector && !comments.overlappingThreadIDs.isEmpty },
            set: { presented in
                if !presented, comments.isPresented == inInspector { comments.overlappingThreadIDs = [] }
            })
    }

    @ViewBuilder
    private var choices: some View {
        ForEach(comments.overlappingThreadIDs, id: \.self) { id in
            if let thread = comments.model?.threads.first(where: { $0.id == id }),
                let active {
                let author = thread.comment.user?.login ?? String(localized: "Unknown author")
                let excerpt = String(thread.comment.parsedBody.text.prefix(80))
                Button("\(author): \(excerpt)") {
                    comments.overlappingThreadIDs = []
                    comments.open(for: active, origin: comments.fileMode, threadID: id)
                }
            }
        }
    }
}
