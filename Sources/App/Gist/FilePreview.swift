import Comments
import Editor
import Preview
import SwiftUI

struct FilePreview: View {
    let editor: MarkdownEditor
    var allowsMutations = true
    var comments: DocumentComments?
    var scrollPosition = ScrollPosition(idType: Int64.self)
    var openThreads: @MainActor ([Int64]) -> Void = { _ in }
    var addComment: @MainActor (String) -> Void = { _ in }
    var matched: @MainActor (Set<Int64>) -> Void = { _ in }
    var openWikilink: (@MainActor (String) -> Void)?

    var body: some View {
        // A refused toggle, while typing or after the file changed, needs no message: the checkbox is
        // controlled, so it springs back and the preview keeps showing the file.
        MarkdownPreviewView(
            document: editor.document, comments: comments, scrollPosition: scrollPosition,
            openThreads: openThreads, addComment: addComment, matched: matched,
            edit: allowsMutations ? { @MainActor in try? editor.apply($0) } : nil, openWikilink: openWikilink)
    }
}
