import Comments
import Editor
import Markdown
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
            markdown: editor.document.text, fileID: editor.id.uuidString,
            generation: editor.generation, allowsTaskEdits: allowsMutations,
            comments: comments, commentActions: commentActions, onEvent: handle
        )
    }

    private func handle(_ event: PreviewEvent) {
        switch event {
        case .taskToggle(let range, _, _, let generation):
            // A refused toggle (typing in progress, or a newer generation) needs no message: the
            // checkbox is controlled, so it springs back and the preview keeps showing the file.
            guard editor.generation == generation, let edit = editor.document.edit(togglingTaskAt: range.location)
            else { return }
            try? editor.apply(edit)
        case .openWikilink(let name):
            openWikilink?(name)
        }
    }
}
