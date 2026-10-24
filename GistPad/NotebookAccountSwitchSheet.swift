import GistPadInterface
import GistPadSync
import SwiftUI
import UniformTypeIdentifiers

struct NotebookAccountSwitchSheet: View {
  let current: String
  let replacement: String
  let export: @MainActor () async throws -> Data
  let switchAccount: @MainActor () async throws -> Void
  let keepCurrent: @MainActor () -> Void
  @State private var isWorking = false
  @State private var error: String?
  @State private var backup: NotebookDraftBackup?
  @State private var showingExporter = false
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent("Current", value: "@\(current)")
          LabeledContent("New account", value: "@\(replacement)")
        } footer: {
          Text("Your drafts stay on this iPhone with their original account. Switching never publishes them.")
        }
        Section {
          Button("Switch to @\(replacement)") {
            work { try await switchAccount() }
          }
          .accessibilityIdentifier("account-switch-confirm")
          Button("Export Current Drafts") {
            work {
              backup = NotebookDraftBackup(data: try await export())
              showingExporter = true
            }
          }
          .accessibilityIdentifier("account-switch-export")
        } footer: {
          Text(
            "Reconnect the original account to return to its drafts. Export makes an additional backup without changing or deleting anything."
          )
        }
        if let error {
          Section {
            Label(error, systemImage: "exclamationmark.circle")
          }
        }
      }
      .navigationTitle("Switch Account")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .cancel, action: keepCurrent) {
            Label("Keep Current Notebook", systemImage: "xmark")
          }
          .tint(.primary)
        }
      }
      .disabled(isWorking)
      .interactiveDismissDisabled(isWorking)
      .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
      .fileExporter(
        isPresented: $showingExporter, document: backup,
        contentType: .json, defaultFilename: "GistPad-\(current)-drafts"
      ) { result in
        if case .failure(let failure) = result {
          error = NotebookModel.message(for: failure)
        }
      }
    }
    .tint(InterfaceTheme.accent)
  }

  private func work(_ operation: @escaping @MainActor () async throws -> Void) {
    guard !isWorking else { return }
    isWorking = true
    Task {
      defer { isWorking = false }
      do {
        try await operation()
        error = nil
      } catch {
        self.error = NotebookModel.message(for: error)
      }
    }
  }
}

private struct NotebookDraftBackup: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  let data: Data

  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
