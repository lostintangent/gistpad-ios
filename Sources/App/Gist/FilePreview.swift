import Comments
import Editor
import Preview
import SwiftUI

struct FilePreview: View {
    let editor: MarkdownEditor
    var allowsMutations = true
    var comments = CommentHighlightConfiguration()
    var commentActions: CommentHighlightActions?
    var openWikilink: ((String) -> Void)?

    var body: some View {
        MarkdownPreviewView(
            markdown: editor.text, fileID: editor.id.uuidString,
            generation: editor.generation, allowsTaskEdits: allowsMutations,
            comments: comments, commentActions: commentActions, onEvent: handle
        )
    }

    private func handle(_ event: PreviewEvent) {
        switch event {
        case .taskToggle(let range, let expected, let replacement, let generation):
            // A refused toggle (typing in progress, or a newer generation) needs no message: the
            // checkbox is controlled, so it springs back and the preview keeps showing the file.
            try? editor.apply(Edit(range: range, expected: expected, replacement: replacement), generation: generation)
        case .openWikilink(let name):
            openWikilink?(name)
        }
    }
}
