import Screens
import SwiftUI

/// A spinner over a file on its way, once it takes a moment.
struct OpeningProgress: View {
  let title: String
  @State private var isSlow = false

  var body: some View {
    ZStack {
      if isSlow {
        ProgressView()
          .accessibilityLabel(Text("Opening \(title)"))
          .accessibilityIdentifier("opening-note-progress")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
      Label("Couldn’t Open This File", systemImage: "exclamationmark.circle")
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
