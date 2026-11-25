import Comments
import Editor
import Preview
import SwiftUI

struct FilePreview: View {
    let editor: MarkdownEditor
    var allowsMutations = true
    var comments: CommentHighlights?
    var openWikilink: ((String) -> Void)?

    var body: some View {
        // A refused toggle, while typing or after the file changed, needs no message: the checkbox is
        // controlled, so it springs back and the preview keeps showing the file.
        MarkdownPreviewView(
            document: editor.document, comments: comments,
            edit: allowsMutations ? { try? editor.apply($0) } : nil, openWikilink: openWikilink)
    }
}
