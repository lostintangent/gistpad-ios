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

  var body: some View {
    NavigationStack {
      List {
        Section {
          Label(current, systemImage: "person.crop.circle")
          Label(replacement, systemImage: "arrow.right.circle")
          Text(
            "Your drafts stay on this iPhone, isolated to their original GitHub account. Switching never publishes them."
          )
        }
        Section {
          Button("Keep Drafts & Switch") {
            work { try await switchAccount() }
          }
          Button("Export Current Drafts") {
            work {
              backup = NotebookDraftBackup(data: try await export())
              showingExporter = true
            }
          }
          Text(
            "Reconnect the original account later to return to its drafts. Exporting makes an additional text backup, without changing or deleting anything."
          )
          .font(.footnote)
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
        }
      }
      .disabled(isWorking)
      .interactiveDismissDisabled(isWorking)
      .fileExporter(
        isPresented: $showingExporter, document: backup,
        contentType: .json, defaultFilename: "GistPad-\(current)-drafts"
      ) { result in
        if case .failure(let failure) = result {
          error = NotebookModel.message(for: failure)
        }
      }
    }
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
