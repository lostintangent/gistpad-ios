import GistPadComments
import GistPadEditor
import GistPadPreview
import SwiftUI

struct SessionPreview: View {
  let session: DocumentSession
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
        document: session.text, documentID: session.documentID,
        generation: session.generation, allowsTaskEdits: allowsMutations,
        comments: comments, onOpenCommentThreads: onOpenCommentThreads,
        onLinkedCommentIDsChange: onLinkedCommentIDsChange, onAddComment: onAddComment,
        onEvent: handle
      )
      .id(reload)
      .accessibilityHidden(renderError != nil)
      .allowsHitTesting(renderError == nil)
      if let renderError {
        ContentUnavailableView {
          Label("Preview unavailable", systemImage: "exclamationmark.triangle")
        } description: {
          Text(renderError)
        } actions: {
          Button("Retry") {
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
      // The bridge only sends toggles for editable notes, for the current generation's exact marker.
      try? session.apply(
        SourceMutation(
          range: edit.range, expected: edit.expectedMarker, replacement: edit.replacementMarker),
        documentID: edit.documentID, generation: edit.generation)
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
