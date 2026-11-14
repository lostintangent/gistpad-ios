import Screens
import SwiftUI

/// A file on its way, under the bar it will have, with a spinner once it takes a moment.
struct OpeningFileView: View {
  let gist: GistDetails
  @State private var isSlow = false

  var body: some View {
    ZStack {
      if isSlow {
        ProgressView()
          .accessibilityLabel(Text("Opening \(gist.title)"))
          .accessibilityIdentifier("opening-note-progress")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .gistTitle(gist)
    .background(Color(uiColor: .systemBackground))
    .task {
      try? await Task.sleep(for: .milliseconds(350))
      isSlow = !Task.isCancelled
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
