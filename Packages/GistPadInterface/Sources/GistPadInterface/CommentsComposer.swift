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
    @Binding private var isFocused: Bool
    private let post: () -> Void
    private let removeContext: (() -> Void)?
    private let didFocus: () -> Void
    @FocusState private var focus: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        text: Binding<String>, context: CommentsComposerContext = .root,
        canPost: Bool, isEditable: Bool = true, isPosting: Bool = false, failure: String? = nil,
        isFocused: Binding<Bool> = .constant(false), post: @escaping () -> Void, removeContext: (() -> Void)? = nil,
        didFocus: @escaping () -> Void = {}
    ) {
        self._text = text
        self.context = context
        self.canPost = canPost
        self.isEditable = isEditable
        self.isPosting = isPosting
        self.failure = failure
        self._isFocused = isFocused
        self.post = post
        self.removeContext = removeContext
        self.didFocus = didFocus
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Like an attachment in the Messages field, the context lives inside the field's glass.
            VStack(alignment: .leading, spacing: 4) {
                if let failure {
                    Text(verbatim: failure)
                        .font(.footnote)
                        .accessibilityIdentifier("comment-post-error")
                }
                if context != .root {
                    contextLine
                }
                TextField(
                    prompt, text: $text, axis: .vertical
                )
                .font(.body)
                .lineLimit(1...maximumLines)
                .textFieldStyle(.plain)
                .focused($focus)
                .disabled(!isEditable || isPosting)
                .accessibilityIdentifier("comment-composer-text")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
            Button(role: .confirm, action: post) {
                Label(String(localized: "Post", bundle: .module), systemImage: "arrow.up")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            // The inspector's compact sheet inherits the dimmed accent of the note it covers at large.
            .tint(Color(uiColor: .tintColor))
            .disabled(!canPost || isPosting)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("comment-post")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .onChange(of: isFocused, initial: true) { _, wanted in
            focus = wanted
        }
        .onChange(of: focus) { _, focused in
            isFocused = focused
            if focused { didFocus() }
        }
        .onDisappear { focus = false }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("comments-composer")
    }

    private var maximumLines: Int {
        if failure != nil { return 1 }
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

    private var contextLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
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
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            if context != .root, let removeContext {
                Button(action: removeContext) {
                    Label(
                        context == .editing
                            ? String(localized: "Cancel editing comment", bundle: .module)
                            : String(localized: "Remove comment context", bundle: .module),
                        systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.tertiary)
                        // A 44-point target that doesn't make the context row taller.
                        .contentShape(.rect.inset(by: -13))
                }
                .buttonStyle(.plain)
                .disabled(!isEditable || isPosting)
                .accessibilityIdentifier("comment-remove-context")
            }
        }
        .font(.footnote)
    }
}

public extension CommentsModel.Failure {
    var interfaceDescription: String {
        switch self {
        case .load:
            String(localized: "Couldn’t reach GitHub. Check your connection and try again.", bundle: .module)
        case .post:
            String(localized: "Your comment couldn’t be posted. Check your connection and try again.", bundle: .module)
        case .edit:
            String(localized: "Your edit couldn’t be saved. Check your connection and try again.", bundle: .module)
        case .delete:
            String(localized: "The comment couldn’t be deleted. Check your connection and try again.", bundle: .module)
        }
    }
}
#endif
