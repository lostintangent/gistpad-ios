import GistPadSync
import SwiftUI

struct NotebookNameEditor: View {
  let title: String
  let fieldTitle: String
  let isFilename: Bool
  let save: @MainActor (String) async throws -> Void
  @State private var value: String
  @State private var isSaving = false
  @State private var error: String?
  @FocusState private var isFocused: Bool
  @Environment(\.dismiss) private var dismiss

  init(
    title: String, fieldTitle: String, initialValue: String, isFilename: Bool = false,
    save: @escaping @MainActor (String) async throws -> Void
  ) {
    self.title = title
    self.fieldTitle = fieldTitle
    self.isFilename = isFilename
    self.save = save
    _value = State(initialValue: initialValue)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField(fieldTitle, text: $value)
            .textInputAutocapitalization(isFilename ? .never : .sentences)
            .autocorrectionDisabled(isFilename)
            .focused($isFocused)
            .submitLabel(.done)
            .onSubmit(commit)
        } footer: {
          if isFilename { Text("Use a Markdown filename ending in .md.") }
        }
        if let error {
          Section {
            Label(error, systemImage: "exclamationmark.circle")
            Button("Retry", action: commit)
              .tint(.primary)
          }
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.disabled(isSaving)
            .tint(.primary)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: commit)
            .tint(.primary)
            .disabled(isSaving || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .disabled(isSaving)
      .interactiveDismissDisabled(isSaving)
      .task { isFocused = true }
    }
  }

  private func commit() {
    guard !isSaving else { return }
    isSaving = true
    Task {
      defer { isSaving = false }
      do {
        try await save(value)
        dismiss()
      } catch {
        self.error = NotebookModel.message(for: error)
      }
    }
  }
}

struct NotebookNameTarget: Identifiable {
  enum Kind { case title, filename, addFile }
  let id = UUID()
  let accountID: UUID
  let draftID: UUID
  let gistID: String?
  let filename: String
  let title: String
  let kind: Kind
}

struct NotebookTagTarget: Identifiable {
  var id: String { "\(accountID.uuidString)/\(gistID)" }
  let accountID: UUID
  let gistID: String
  let selected: Set<String>
  let canEdit: Bool
}

struct NotebookDeletionTarget: Identifiable {
  let id: String
  let accountID: UUID
  let title: String
  var localDraft: DraftSnapshot? = nil
  // The local snapshot lags an in-flight create, so a publish in progress counts as possibly sent.
  var isPublishing = false
  // Daily notes delete one day's file; nil deletes the whole gist.
  var filename: String? = nil

  var isUncertainCreation: Bool {
    localDraft.map { $0.gistID == nil && ($0.attemptedGeneration != nil || isPublishing) } ?? false
  }

  var action: NotebookAction {
    if let localDraft {
      if isUncertainCreation {
        .discardUncertainCreation(draftID: localDraft.id, generation: localDraft.generation)
      } else {
        .discardLocalCopy(draftID: localDraft.id, generation: localDraft.generation)
      }
    } else if let filename {
      .deleteFile(gistID: id, filename: filename)
    } else {
      .delete(gistID: id)
    }
  }
}
