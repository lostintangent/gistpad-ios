import Screens
import Model
import Preview
import SwiftUI

struct OpeningFileView: View {
  let gist: GistDetails
  var file: GistFile?
  @State private var progressTitle: String?

  var body: some View {
    Group {
      if let file {
        // A failed render shows once the note opens, in its own Preview.
        MarkdownPreviewView(
          markdown: file.text, fileID: file.id.uuidString,
          generation: 0, allowsTaskEdits: false
        ) { _ in }
        .allowsHitTesting(false)
        .accessibilityIdentifier("opening-cached-note")
      } else {
        ZStack {
          if progressTitle == gist.title {
            ProgressView()
              .accessibilityLabel(Text("Opening \(gist.title)"))
              .accessibilityIdentifier("opening-note-progress")
          }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .gistTitle(gist)
    .background(Color(uiColor: .systemBackground))
    .task(id: file == nil ? gist.title : nil) {
      progressTitle = nil
      guard file == nil else { return }
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      progressTitle = gist.title
    }
  }
}

struct OpenFailedView: View {
  let gist: GistDetails
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
    .gistTitle(gist)
  }
}
