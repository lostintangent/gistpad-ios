import Comments
import Editor
import Preview
import SwiftUI

struct FilePreview: View {
  let editor: Editor
  var allowsMutations = true
  var comments = CommentHighlightConfiguration()
  var onOpenCommentThreads: (@MainActor ([Int64]) -> Void)?
  var onLinkedCommentIDsChange: (@MainActor (Set<Int64>) -> Void)?
  var onAddComment: (@MainActor (String) -> Void)?
  var openWikilink: ((String) -> Void)?
  @State private var renderError: String?
  @State private var reload = 0
  @Environment(\.openURL) private var openURL

  var body: some View {
    ZStack {
      MarkdownPreviewView(
        markdown: editor.text, fileID: editor.fileID,
        generation: editor.generation, allowsTaskEdits: allowsMutations,
        comments: comments, onOpenCommentThreads: onOpenCommentThreads,
        onLinkedCommentIDsChange: onLinkedCommentIDsChange, onAddComment: onAddComment,
        onEvent: handle
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
    case .taskToggle(let edit):
      // A refused toggle (typing in progress, or a newer generation) needs no message: the
      // checkbox is controlled, so it springs back and the preview keeps showing the file.
      try? editor.apply(
        Edit(
          range: edit.range, expected: edit.expectedMarker, replacement: edit.replacementMarker),
        generation: edit.generation)
    case .linkTapped(let link):
      if link.kind == .external, let url = URL(string: link.target) {
        openURL(url)
      } else if link.kind == .wikilink {
        openWikilink?(link.target)
      }
    case .failure(let failure):
      renderError = failure.localizedDescription
    case .rendered:
      break
    }
  }
}
