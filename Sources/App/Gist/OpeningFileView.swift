import Interface
import Preview
import OSLog
import SwiftUI

struct OpeningFileView: View {
  let title: String
  var file: File?
  @State private var renderError: String?
  @State private var reload = 0
  @State private var progressTitle: String?

  var body: some View {
    Group {
      if let file {
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
            .frame(minHeight: 44)
          }
        } else {
          MarkdownPreviewView(
            markdown: file.draft.text, fileID: file.id,
            generation: file.draft.generation, allowsTaskEdits: false
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
            ProgressView()
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
    .task(id: file == nil ? title : nil) {
      progressTitle = nil
      guard file == nil else { return }
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

struct OpenFailedView: View {
  let opening: Opening
  let message: String
  let retry: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Couldn't Open This File", systemImage: "exclamationmark.circle")
    } description: {
      Text(message)
    } actions: {
      Button("Try Again", action: retry)
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("note-open-retry")
    }
    .navigationTitle(opening.title)
    .navigationSubtitle(opening.filename ?? "")
    .navigationBarTitleDisplayMode(.inline)
  }
}
