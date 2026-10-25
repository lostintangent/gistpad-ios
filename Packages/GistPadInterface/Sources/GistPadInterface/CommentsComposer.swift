#if os(iOS)
import GistPadComments
import SwiftUI

public enum CommentsComposerContext: Equatable, Sendable {
    case root
    case reply(author: String?)
    case quote(text: String, filename: String)
    case editing
}

public struct CommentsComposer: View {
    @Binding private var text: String
    private let context: CommentsComposerContext
    private let canPost: Bool
    private let isEditable: Bool
    private let isPosting: Bool
    private let failure: String?
    private let draftSaveFailure: String?
    private let focusRequest: UInt64
    private let post: () -> Void
    private let removeContext: (() -> Void)?
    private let retryDraftSave: (() -> Void)?
    private let didFocus: () -> Void
    @FocusState private var isFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        text: Binding<String>, context: CommentsComposerContext = .root,
        canPost: Bool, isEditable: Bool = true, isPosting: Bool = false, failure: String? = nil,
        draftSaveFailure: String? = nil, focusRequest: UInt64 = 0,
        post: @escaping () -> Void, removeContext: (() -> Void)? = nil,
        retryDraftSave: (() -> Void)? = nil, didFocus: @escaping () -> Void = {}
    ) {
        self._text = text
        self.context = context
        self.canPost = canPost
        self.isEditable = isEditable
        self.isPosting = isPosting
        self.failure = failure
        self.draftSaveFailure = draftSaveFailure
        self.focusRequest = focusRequest
        self.post = post
        self.removeContext = removeContext
        self.retryDraftSave = retryDraftSave
        self.didFocus = didFocus
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let draftSaveFailure {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: draftSaveFailure)
                        .fixedSize(horizontal: false, vertical: true)
                    if let retryDraftSave {
                        Button(action: retryDraftSave) {
                            Text(String(localized: "Save Draft Again", bundle: .module))
                                .frame(minHeight: 44)
                        }
                    }
                }
                .font(.footnote)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("comment-draft-error")
            }
            if let failure {
                Text(verbatim: failure)
                    .font(.footnote)
                    .accessibilityIdentifier("comment-post-error")
            }
            if context != .root {
                contextLine
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    prompt, text: $text, axis: .vertical
                )
                .font(.body)
                .lineLimit(1...maximumLines)
                .textFieldStyle(.plain)
                .frame(minHeight: 44)
                .focused($isFocused)
                .tint(Color(uiColor: .systemBlue))
                .disabled(!isEditable || isPosting)
                .accessibilityIdentifier("comment-composer-text")
                Button(action: post) {
                    Group {
                        if isPosting {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .disabled(!canPost || isPosting)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(Text(verbatim: sendLabel))
                .accessibilityIdentifier("comment-post")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .tint(.primary)
        .onChange(of: focusRequest, initial: true) { _, request in
            isFocused = request > 0
        }
        .onChange(of: isFocused) { _, focused in
            if focused { didFocus() }
        }
        .onDisappear { isFocused = false }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("comments-composer")
    }

    private var maximumLines: Int {
        if failure != nil || draftSaveFailure != nil { return 1 }
        return dynamicTypeSize.isAccessibilitySize ? 2 : 5
    }

    private var prompt: String {
        switch context {
        case .reply:
            String(localized: "Write a reply", bundle: .module)
        case .editing:
            String(localized: "Edit your comment", bundle: .module)
        case .root, .quote:
            String(localized: "Write a comment", bundle: .module)
        }
    }

    private var sendLabel: String {
        switch context {
        case .reply:
            String(localized: "Post reply to GitHub", bundle: .module)
        case .editing:
            String(localized: "Save comment to GitHub", bundle: .module)
        case .root, .quote:
            String(localized: "Post comment to GitHub", bundle: .module)
        }
    }

    private var contextLine: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch context {
                case .root:
                    EmptyView()
                case .reply(let author):
                    if let author {
                        Text("Replying to @\(author)", bundle: .module)
                    } else {
                        Text("Replying to a comment", bundle: .module)
                    }
                case .quote(let text, let filename):
                    Label {
                        Text(verbatim: text)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1 : 2)
                    } icon: {
                        Image(systemName: "quote.opening")
                    }
                    .accessibilityLabel(
                        Text("Selected from \(filename): \(text)", bundle: .module))
                case .editing:
                    Text("Editing your comment", bundle: .module)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            if context != .root, let removeContext {
                Button(action: removeContext) {
                    Label(
                        context == .editing
                            ? String(localized: "Cancel editing comment", bundle: .module)
                            : String(localized: "Remove comment context", bundle: .module),
                        systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .disabled(!isEditable || isPosting)
                .accessibilityIdentifier("comment-remove-context")
            }
        }
    }
}

public extension CommentConversationProblem {
    var interfaceDescription: String {
        switch self {
        case .remote(let failure):
            switch failure {
            case .network:
                String(localized: "Comments need an internet connection. Try again when you’re online.", bundle: .module)
            case .authentication:
                String(localized: "Reconnect GitHub from your account in the Library, then refresh comments.", bundle: .module)
            case .forbidden:
                String(localized: "Your GitHub account doesn’t have permission to make this change.", bundle: .module)
            case .notFound:
                String(localized: "This conversation is no longer available to your GitHub account.", bundle: .module)
            case .invalidRequest:
                String(localized: "GitHub couldn’t accept this comment. Check the text and try again.", bundle: .module)
            case .http(let status, let deadline):
                if let deadline {
                    String(
                        localized: "GitHub is limiting requests. Try again after \(deadline.formatted(.dateTime.month().day().hour().minute())).",
                        bundle: .module)
                } else if status == 429 {
                    String(localized: "GitHub is limiting requests. Wait a moment, then try again.", bundle: .module)
                } else {
                    String(localized: "GitHub couldn’t finish the request. Refresh comments and try again.", bundle: .module)
                }
            case .invalidResponse:
                String(localized: "GitHub’s response couldn’t be read. Refresh comments before trying again.", bundle: .module)
            }
        case .localStorage:
            String(localized: "Your draft isn’t saved on this device.", bundle: .module)
        case .missingTarget:
            String(localized: "This comment is no longer available. Your draft has not been posted.", bundle: .module)
        case .replyDepthLimit:
            String(localized: "This reply is already at the deepest supported level. Reply to its parent instead.", bundle: .module)
        case .notAllowed:
            String(localized: "Your GitHub account doesn’t have permission to change this comment.", bundle: .module)
        case .commentChanged:
            String(localized: "This comment changed on GitHub. Your text is unchanged. Refresh before editing it again.", bundle: .module)
        case .emptyBody:
            String(localized: "Write a comment before posting.", bundle: .module)
        case .invalidSelection:
            String(localized: "Select at least four characters to comment on a passage.", bundle: .module)
        case .busy:
            String(localized: "Wait for the current comment operation to finish.", bundle: .module)
        case .unresolvedMutation:
            String(localized: "Refresh comments to check the previous change before posting again.", bundle: .module)
        case .unconfirmedMutation:
            String(localized: "GitHub hasn’t confirmed the change. Your draft is unchanged. You can try again.", bundle: .module)
        case .existingRootDraft:
            String(localized: "You have an unfinished new comment. Choose New Comment to return to it.", bundle: .module)
        }
    }
}
#endif
