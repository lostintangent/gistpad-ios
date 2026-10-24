import GistPadEditor
import GistPadPreview
import SwiftUI

struct SessionPreview: View {
  let session: DocumentSession
  var allowsMutations = true
  var openWikilink: ((String) -> Void)?
  @State private var renderError: String?
  @State private var interactionError: String?
  @State private var reload = 0
  @Environment(\.openURL) private var openURL

  var body: some View {
    ZStack {
      MarkdownPreviewView(
        document: session.text, documentID: session.documentID,
        generation: session.generation, onEvent: handle
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
          .buttonStyle(.borderedProminent)
        }
        .background(Color(uiColor: .systemBackground))
      }
    }
    .alert(
      "Couldn't complete that action",
      isPresented: Binding(
        get: { interactionError != nil },
        set: { if !$0 { interactionError = nil } })
    ) {
      Button("OK") { interactionError = nil }
    } message: {
      Text(interactionError ?? "")
    }
  }

  private func handle(_ event: PreviewEvent) {
    switch event {
    case .taskToggle(let edit):
      guard allowsMutations else {
        interactionError = String(localized: "This gist is read-only. Its tasks cannot be changed.")
        return
      }
      do {
        try edit.validate(
          in: session.text, documentID: session.documentID, generation: session.generation)
        try session.apply(
          SourceMutation(
            range: edit.range, expected: edit.expectedMarker, replacement: edit.replacementMarker),
          documentID: edit.documentID, generation: edit.generation)
      } catch {
        interactionError = String(
          localized:
            "The source changed before this task could be updated. Try it again after composition or Writing Tools finishes."
        )
      }
    case .linkTapped(let link):
      if link.kind == .external, let url = URL(string: link.target) {
        openURL(url)
      } else if link.kind == .wikilink {
        if let openWikilink {
          openWikilink(link.target)
        } else {
          interactionError = String(
            localized: "Wikilinks are not connected in this editor fixture.")
        }
      }
    case .failure(let failure):
      renderError = failure.localizedDescription
    case .contentHeight, .rendered:
      break
    }
  }
}
