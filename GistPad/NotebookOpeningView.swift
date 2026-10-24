import GistPadPreview
import SwiftUI

struct NotebookOpeningView: View {
  let title: String
  var document: NotebookDocument?
  @State private var renderError: String?

  var body: some View {
    Group {
      if let document {
        if let renderError {
          ContentUnavailableView(
            "Preview unavailable", systemImage: "exclamationmark.triangle",
            description: Text(renderError))
        } else {
          MarkdownPreviewView(
            document: document.text, documentID: document.id,
            generation: document.draft?.generation ?? 0, allowsTaskEdits: false
          ) { event in
            if case .failure(let failure) = event { renderError = failure.localizedDescription }
          }
          .allowsHitTesting(false)
          .accessibilityIdentifier("opening-cached-note")
        }
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text("A little room for your thoughts").font(.title2.bold())
            Text("The words in this note will appear here.")
            Text("One thought, then another.")
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(24)
          .redacted(reason: .placeholder)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text("Loading \(title)"))
        }
        .scrollDisabled(true)
        .accessibilityIdentifier("opening-uncached-note")
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .background(Color(uiColor: .systemBackground))
  }
}
