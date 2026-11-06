import Sync
import SwiftUI

struct RenameSheet: View {
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
              .foregroundStyle(.primary)
            Button("Try Again", action: commit)
          }
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .cancel) { dismiss() }.disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          if isSaving {
            ProgressView()
          } else {
            Button(role: .confirm, action: commit)
              .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
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
        self.error = error.localizedDescription
      }
    }
  }
}

struct RenameTarget: Identifiable {
  enum Kind { case title, filename, addFile }
  let id = UUID()
  let draft: Draft
  let title: String
  let kind: Kind
}

struct TagTarget: Identifiable {
  var id: String { "\(accountID.uuidString)/\(gistID)" }
  let accountID: UUID
  let gistID: String
  let selected: Set<String>
  let canEdit: Bool
}
