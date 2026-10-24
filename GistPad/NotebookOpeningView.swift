import GistPadInterface
import GistPadPreview
import SwiftUI

struct NotebookOpeningView: View {
  let title: String
  var document: NotebookDocument?
  @State private var renderError: String?
  @State private var reload = 0

  var body: some View {
    Group {
      if let document {
        if let renderError {
          ContentUnavailableView {
            Label("Preview unavailable", systemImage: "exclamationmark.triangle")
          } description: {
            Text(renderError)
          } actions: {
            Button("Try Again") {
              self.renderError = nil
              reload += 1
            }
            .frame(minHeight: 44)
          }
        } else {
          MarkdownPreviewView(
            document: document.text, documentID: document.id,
            generation: document.draft?.generation ?? 0, allowsTaskEdits: false
          ) { event in
            if case .failure(let failure) = event { renderError = failure.localizedDescription }
          }
          .id(reload)
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
    .tint(InterfaceTheme.accent)
  }
}

struct NotebookFailedOpeningView: View {
  let failure: NotebookFailedOpen
  let retry: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Couldn't Open Note", systemImage: "exclamationmark.circle")
    } description: {
      Text(failure.message)
    } actions: {
      Button("Try Again", action: retry)
        .frame(minHeight: 44)
        .buttonStyle(.borderedProminent)
        .tint(InterfaceTheme.accentFill)
        .foregroundStyle(InterfaceTheme.onAccent)
        .accessibilityIdentifier("note-open-retry")
    }
    .navigationTitle(failure.title)
    .navigationSubtitle(failure.filename ?? "")
    .navigationBarTitleDisplayMode(.inline)
    .tint(InterfaceTheme.accent)
  }
}
