import Comments
import SwiftUI

struct CommentsComposer: View {
    let comments: CommentsPresentation
    @Bindable var model: CommentsModel
    @FocusState private var focus: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var failure: String? {
        model.failure == .load ? nil : model.failure?.interfaceDescription
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Like an attachment in the Messages field, the context lives inside the field's glass.
            VStack(alignment: .leading, spacing: 4) {
                if let failure {
                    Text(verbatim: failure)
                        .font(.footnote)
                        .accessibilityIdentifier("comment-post-error")
                }
                if model.target != .root {
                    contextLine
                }
                TextField(
                    prompt, text: $model.draft, axis: .vertical
                )
                .font(.body)
                .lineLimit(1...maximumLines)
                .textFieldStyle(.plain)
                .focused($focus)
                .disabled(model.isPosting)
                .accessibilityIdentifier("comment-composer-text")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
            Button(role: .confirm) {
                Task { await model.post() }
            } label: {
                Label("Post", systemImage: "arrow.up")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            // Platform gap: the inspector's compact sheet inherits the dimmed tint of the gist it covers at
            // large. Remove this tint when a sheet's controls keep the full accent.
            .tint(Color(uiColor: .tintColor))
            .disabled(!model.canPost)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("comment-post")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .onChange(of: comments.isComposerFocused, initial: true) { _, wanted in
            focus = wanted
        }
        .onChange(of: focus) { _, focused in
            comments.isComposerFocused = focused
            if focused { comments.detent = .large }
        }
        .onDisappear { focus = false }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("comments-composer")
    }

    private var maximumLines: Int {
        if failure != nil { return 1 }
        return dynamicTypeSize.isAccessibilitySize ? 2 : 5
    }

    private var prompt: LocalizedStringKey {
        switch model.target {
        case .reply: "Write a reply"
        case .edit: "Edit your comment"
        case .root, .quote: "Write a comment"
        }
    }

    private var contextLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                switch model.target {
                case .root:
                    EmptyView()
                case .reply(let id):
                    if let author = model.comments?.first(where: { $0.id == id })?.user?.login {
                        Text("Replying to @\(author)")
                    } else {
                        Text("Replying to a comment")
                    }
                case .quote(let text, let filename):
                    Label {
                        Text(verbatim: text)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1 : 2)
                    } icon: {
                        Image(systemName: "quote.opening")
                    }
                    .accessibilityLabel(Text("Quoting \(filename): \(text)"))
                case .edit:
                    Text("Editing your comment")
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if case .edit = model.target { comments.isComposerFocused = false } else { comments.focusComposer() }
                model.removeContext()
            } label: {
                Label(clearTitle, systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tertiary)
                    // A 44-point target that doesn't make the context row taller.
                    .contentShape(.rect.inset(by: -13))
            }
            .buttonStyle(.plain)
            .disabled(model.isPosting)
            .accessibilityIdentifier("comment-remove-context")
        }
        .font(.footnote)
    }

    private var clearTitle: LocalizedStringKey {
        switch model.target {
        case .reply: "Cancel Reply"
        case .edit: "Cancel Editing"
        case .root, .quote: "Remove Quote"
        }
    }
}

extension CommentsModel.Failure {
    var interfaceDescription: String {
        switch self {
        case .load:
            String(localized: "Couldn’t reach GitHub. Check your connection and try again.")
        case .post:
            String(localized: "Your comment couldn’t be posted. Check your connection and try again.")
        case .delete:
            String(localized: "This comment couldn’t be deleted. Check your connection and try again.")
        }
    }
}
