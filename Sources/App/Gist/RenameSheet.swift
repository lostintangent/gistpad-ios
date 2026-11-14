import Store
import SwiftUI

struct RenameSheet: View {
  let target: RenameTarget
  let save: @MainActor (String) async throws -> Void
  @State private var value: String
  @State private var isSaving = false
  @State private var error: String?
  @FocusState private var isFocused: Bool
  @Environment(\.dismiss) private var dismiss

  init(_ target: RenameTarget, save: @escaping @MainActor (String) async throws -> Void) {
    self.target = target
    self.save = save
    _value = State(initialValue: target.initialValue)
  }

  private var isFilename: Bool { target.kind != .title }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField(
            isFilename ? String(localized: "Filename") : String(localized: "Name"), text: $value)
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
          }
        }
      }
      .navigationTitle(target.heading)
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
  let draft: GistFileDraft
  let title: String
  let kind: Kind

  var heading: String {
    switch kind {
    case .title: String(localized: "Rename Gist")
    case .filename: String(localized: "Rename File")
    case .addFile: String(localized: "Add File")
    }
  }

  var initialValue: String {
    switch kind {
    case .title: title
    case .filename: draft.filename
    case .addFile: ""
    }
  }
}

struct TagTarget: Identifiable {
  var id: String { "\(accountID.uuidString)/\(gistID)" }
  let accountID: UUID
  let gistID: String
  let selected: Set<String>
  let canEdit: Bool
}
