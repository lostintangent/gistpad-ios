import Comments
import Editor
import Preview
import SwiftUI

struct FilePreview: View {
    let editor: Editor
    var allowsMutations = true
    var comments = CommentHighlightConfiguration()
    var commentActions: CommentHighlightActions?
    var openWikilink: ((String) -> Void)?
    @State private var renderError: String?
    @State private var reload = 0
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            MarkdownPreviewView(
                markdown: editor.text, fileID: editor.id.uuidString,
                generation: editor.generation, allowsTaskEdits: allowsMutations,
                comments: comments, commentActions: commentActions, onEvent: handle
            )
            .id(reload)
            .accessibilityHidden(renderError != nil)
            .allowsHitTesting(renderError == nil)
            if let renderError {
                ContentUnavailableView {
                    Label("Preview Unavailable", systemImage: "exclamationmark.circle")
                } description: {
                    Text(renderError)
                } actions: {
                    Button("Try Again") {
                        self.renderError = nil
                        reload += 1
                    }
                }
                .background(Color(uiColor: .systemBackground))
            }
        }
    }

    private func handle(_ event: PreviewEvent) {
        switch event {
        case .taskToggle(let range, let expected, let replacement, let generation):
            // A refused toggle (typing in progress, or a newer generation) needs no message: the
            // checkbox is controlled, so it springs back and the preview keeps showing the file.
            try? editor.apply(Edit(range: range, expected: expected, replacement: replacement), generation: generation)
        case .openURL(let url):
            openURL(url)
        case .openWikilink(let name):
            openWikilink?(name)
        case .failure(let message):
            renderError = message
        }
    }
}
