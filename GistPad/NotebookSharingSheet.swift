import GistPadInterface
import GistPadSync
import SwiftUI

struct NotebookSharingTarget: Identifiable {
  let id = UUID()
  let controller: NotebookSessionController
  let copiesLink: Bool
}

enum NotebookSharingError: LocalizedError {
  case saveNotConfirmed
  case draftChangedWhileSaving

  var errorDescription: String? {
    switch self {
    case .saveNotConfirmed:
      String(
        localized:
          "GitHub hasn't confirmed the current draft. Nothing was shared. Return to the note to review its save status."
      )
    case .draftChangedWhileSaving:
      String(
        localized:
          "Your draft changed while saving. Nothing was shared. Save the latest version or choose its saved link."
      )
    }
  }
}

struct NotebookSharingSheet: View {
  let controller: NotebookSessionController
  let copiesLink: Bool
  @State private var links: DocumentLinks?
  @State private var isWorking = false
  @State private var error: String?
  @State private var shareItem: NotebookShareItem?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(controller.chrome.title).font(.headline)
          if controller.document.gist?.isPublic != true {
            Label("Secret gist", systemImage: "lock")
            Text("Anyone with a shared link can read the saved note.")
          }
          if controller.document.isRecovery {
            Text(
              "The original GitHub note is unavailable. You can share a copy of this local draft.")
          } else if controller.hasUnpublishedChanges {
            Text(
              links == nil
                ? "This draft does not have a saved-file link yet. Save it to GitHub to create one."
                : "Links show the saved GitHub version. Your latest changes on this iPhone are not included."
            )
          }
        }
        Section {
          if links != nil {
            Button(copiesLink ? "Copy saved link" : "Share saved link") {
              work { try deliverSavedLink() }
            }
          }
          if controller.canMutate, !controller.document.isRecovery,
            controller.saveState.canPublish || controller.saveState == .savedToGitHub
          {
            Button(copiesLink ? "Save & Copy Link" : "Save & Share") {
              work {
                if controller.saveState.canPublish { await controller.publish() }
                guard controller.saveState == .savedToGitHub else {
                  throw NotebookSharingError.saveNotConfirmed
                }
                guard !controller.hasUnpublishedChanges else {
                  throw NotebookSharingError.draftChangedWhileSaving
                }
                try await controller.refreshPublicationMetadata()
                try deliverSavedLink()
              }
            }
          }
          Button(copiesLink ? "Copy draft text" : "Share draft text") {
            if copiesLink {
              UIPasteboard.general.string = controller.session.text
              UIAccessibility.post(
                notification: .announcement, argument: String(localized: "Draft text copied"))
              dismiss()
            } else {
              shareItem = .text(controller.session.text)
            }
          }
        }
        if let error {
          Section {
            Label(error, systemImage: "exclamationmark.circle")
          }
        }
      }
      .navigationTitle(
        copiesLink ? String(localized: "Copy Link") : String(localized: "Share Note")
      )
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }.disabled(isWorking)
        }
      }
      .disabled(isWorking)
      .interactiveDismissDisabled(isWorking)
      .task { reloadLinks() }
      .sheet(item: $shareItem) { item in NotebookActivitySheet(item: item) }
    }
  }

  private func reloadLinks() {
    do {
      links = try controller.savedLinks()
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func deliverSavedLink() throws {
    guard let links = try controller.savedLinks() else { throw DocumentLinkError.notPublished }
    if copiesLink {
      UIPasteboard.general.url = links.shareURL
      UIAccessibility.post(notification: .announcement, argument: String(localized: "Link copied"))
      dismiss()
    } else {
      shareItem = .url(links.shareURL)
    }
  }

  private func work(_ operation: @escaping @MainActor () async throws -> Void) {
    guard !isWorking else { return }
    isWorking = true
    Task {
      defer { isWorking = false }
      do {
        try await operation()
        links = try controller.savedLinks()
        error = nil
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}

enum NotebookShareItem: Identifiable {
  case url(URL)
  case text(String)

  var id: String {
    switch self {
    case .url(let url): "url:\(url.absoluteString)"
    case .text: "draft-text"
    }
  }
}

struct NotebookActivitySheet: UIViewControllerRepresentable {
  let item: NotebookShareItem

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let items: [Any] =
      switch item {
      case .url(let url): [url]
      case .text(let text): [text]
      }
    return UIActivityViewController(activityItems: items, applicationActivities: nil)
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
