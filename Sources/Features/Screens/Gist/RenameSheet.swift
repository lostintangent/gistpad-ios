#if os(iOS)
import Store
import SwiftUI

public struct RenameSheet: View {
    let target: RenameTarget
    let save: @MainActor (String) async throws -> Void
    @State private var value: String
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    public init(_ target: RenameTarget, save: @escaping @MainActor (String) async throws -> Void) {
        self.target = target
        self.save = save
        _value = State(initialValue: target.initialValue)
    }

    private var isFilename: Bool { target.kind != .title }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        isFilename
                            ? String(localized: "Filename", bundle: .module)
                            : String(localized: "Name", bundle: .module),
                        text: $value)
                        .textInputAutocapitalization(isFilename ? .never : .sentences)
                        .autocorrectionDisabled(isFilename)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit(commit)
                } footer: {
                    if isFilename { Text("Use a Markdown filename ending in .md.", bundle: .module) }
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
                self.error = Failure(error).message
            }
        }
    }
}

public struct RenameTarget: Identifiable {
    public enum Kind { case title, filename, addFile }
    public let id = UUID()
    public let draft: GistFileDraft
    public let title: String
    public let kind: Kind

    public init(draft: GistFileDraft, title: String, kind: Kind) {
        self.draft = draft
        self.title = title
        self.kind = kind
    }

    var heading: String {
        switch kind {
        case .title: String(localized: "Rename Gist", bundle: .module)
        case .filename: String(localized: "Rename File", bundle: .module)
        case .addFile: String(localized: "Add File", bundle: .module)
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
#endif
