import GistPadInterface
import GistPadPreview
import OSLog
import SwiftUI

struct NotebookOpeningView: View {
  let title: String
  var document: NotebookDocument?
  @State private var renderError: String?
  @State private var reload = 0
  @State private var progressTitle: String?

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
        ZStack {
          if progressTitle == title {
            VStack(spacing: 12) {
              ProgressView()
                .controlSize(.regular)
              Text("Opening note...")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Opening \(title)"))
            .accessibilityIdentifier("opening-note-progress")
          }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .background(Color(uiColor: .systemBackground))
    .task(id: document == nil ? title : nil) {
      progressTitle = nil
      guard document == nil else { return }
      do {
        try await Task.sleep(for: .milliseconds(350))
        progressTitle = title
      } catch is CancellationError {
        return
      } catch {
        Logger(subsystem: "dev.gistpad.GistPad", category: "Opening")
          .error("The opening progress delay failed: \(error.localizedDescription, privacy: .public)")
      }
    }
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
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("note-open-retry")
    }
    .navigationTitle(failure.title)
    .navigationSubtitle(failure.filename ?? "")
    .navigationBarTitleDisplayMode(.inline)
  }
}
