#if os(iOS)
import SwiftUI

public struct TagEditor: View {
    private let save: (@MainActor ([TagEdit]) async throws -> Void)?
    @State private var draft: TagEditorDraft
    @State private var query = ""
    @State private var editingTag: LibraryTag?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var confirmingDiscard = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        tags: [LibraryTag], selectedTagIDs: Set<String>,
        save: (@MainActor ([TagEdit]) async throws -> Void)? = nil
    ) {
        self.save = save
        _draft = State(initialValue: TagEditorDraft(tags: tags, selectedTagIDs: selectedTagIDs))
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    if selectedTags.isEmpty {
                        Text(
                            save == nil && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? String(localized: "No matching tags.", bundle: .module)
                                : String(localized: "No tags on this note.", bundle: .module)
                        )
                            .foregroundStyle(.primary)
                    } else {
                        TagLabels(tags: selectedTags)
                    }
                } header: {
                    Text("On this note", bundle: .module).foregroundStyle(InterfaceTheme.text)
                } footer: {
                    Text("Tags apply to every file in this gist.", bundle: .module)
                        .foregroundStyle(.primary)
                }
                if let saveError {
                    Section {
                        Label(String(localized: "Couldn't finish saving tags.", bundle: .module), systemImage: "exclamationmark.circle")
                        Text(verbatim: saveError).font(.subheadline)
                        Text("Some changes may already be saved. Retry to finish applying your choices.", bundle: .module)
                            .font(.footnote)
                        Button(String(localized: "Retry", bundle: .module), action: commit)
                    }
                    .foregroundStyle(.primary)
                }
                if save != nil {
                    Section {
                        ForEach(matchingTags) { tag in editableRow(tag) }
                        if matchingTags.isEmpty {
                            Text("No matching tags.", bundle: .module)
                        }
                    } header: {
                        Text("All tags", bundle: .module).foregroundStyle(InterfaceTheme.text)
                    }
                } else {
                    Section {
                        Label(String(localized: "Tags are read-only", bundle: .module), systemImage: "eye")
                    }
                    .foregroundStyle(.primary)
                }
            }
            .navigationTitle(Text("Tags", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .tint(InterfaceTheme.accent)
            .searchable(text: $query, prompt: Text("Search tags", bundle: .module))
            .toolbar { toolbar }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving || !draft.edits.isEmpty)
            .sheet(item: $editingTag) { tag in
                TagEditForm(
                    tag: tag, isNew: !draft.tags.contains(where: { $0.id == tag.id }),
                    update: { try draft.upsert($0) },
                    delete: { draft.delete(tag) }
                )
            }
            .confirmationDialog(
                draft.hasAttemptedChanges
                    ? String(localized: "Close without retrying?", bundle: .module)
                    : String(localized: "Discard tag changes?", bundle: .module),
                isPresented: $confirmingDiscard, titleVisibility: .visible
            ) {
                Button(
                    draft.hasAttemptedChanges
                        ? String(localized: "Close", bundle: .module)
                        : String(localized: "Discard changes", bundle: .module),
                    role: .destructive
                ) { dismiss() }
                Button(String(localized: "Keep editing", bundle: .module), role: .cancel) {}
            } message: {
                if draft.hasAttemptedChanges {
                    Text("Some changes may already be saved. Closing does not undo saved changes.", bundle: .module)
                }
            }
        }
    }

    private var selectedTags: [LibraryTag] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.tags.filter {
            draft.selectedTagIDs.contains($0.id)
                && (save != nil || query.isEmpty || $0.name.localizedStandardContains(query))
        }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var matchingTags: [LibraryTag] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.tags.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func editableRow(_ tag: LibraryTag) -> some View {
        Button {
            if draft.selectedTagIDs.contains(tag.id) {
                draft.selectedTagIDs.remove(tag.id)
            } else {
                draft.selectedTagIDs.insert(tag.id)
            }
        } label: {
            HStack(spacing: 12) {
                TagSwatch(hex: tag.colorHex)
                Text(verbatim: tag.name).foregroundStyle(.primary)
                Spacer()
                if draft.selectedTagIDs.contains(tag.id) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(InterfaceTheme.accent)
                        .transition(.opacity)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(draft.selectedTagIDs.contains(tag.id) ? .isSelected : [])
        .accessibilityAction(named: Text("Edit tag \(tag.name)", bundle: .module)) { editingTag = tag }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: draft.selectedTagIDs.contains(tag.id))
        .contextMenu {
            Button(String(localized: "Edit Tag…", bundle: .module), systemImage: "pencil") { editingTag = tag }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(String(localized: "Edit Tag…", bundle: .module), systemImage: "pencil") { editingTag = tag }
                .tint(InterfaceTheme.accent)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if save != nil {
            ToolbarItem(placement: .cancellationAction) {
                Button(
                    draft.hasAttemptedChanges
                        ? String(localized: "Close", bundle: .module)
                        : String(localized: "Cancel", bundle: .module)
                ) {
                    if draft.edits.isEmpty { dismiss() } else { confirmingDiscard = true }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Add tag", bundle: .module), systemImage: "plus") {
                    editingTag = LibraryTag(id: UUID().uuidString, name: "")
                }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            if isSaving {
                ProgressView(String(localized: "Saving tags", bundle: .module))
            } else {
                Button(String(localized: "Done", bundle: .module), action: commit)
            }
        }
    }

    private func commit() {
        guard let save, !draft.edits.isEmpty else { dismiss(); return }
        guard !isSaving else { return }
        let edits = draft.edits
        draft.recordAttempt(edits)
        isSaving = true
        saveError = nil
        Task {
            do {
                try await save(edits)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}

private struct TagEditForm: View {
    let tag: LibraryTag
    let isNew: Bool
    let update: (LibraryTag) throws -> Void
    let delete: () -> Void
    @State private var name: String
    @State private var colorHex: String?
    @State private var error: String?
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(
        tag: LibraryTag, isNew: Bool, update: @escaping (LibraryTag) throws -> Void,
        delete: @escaping () -> Void
    ) {
        self.tag = tag
        self.isNew = isNew
        self.update = update
        self.delete = delete
        _name = State(initialValue: tag.name)
        _colorHex = State(initialValue: tag.colorHex)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Tag name", bundle: .module), text: $name)
                        .focused($nameFocused)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    ColorPicker(String(localized: "Color", bundle: .module), selection: color, supportsOpacity: false)
                    if colorHex != nil {
                        Button(String(localized: "Use default color", bundle: .module)) { colorHex = nil }
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.primary)
                    }
                }
                if !name.isEmpty {
                    Section {
                        TagLabel(tag: LibraryTag(id: tag.id, name: name, colorHex: colorHex))
                    } header: {
                        Text("Preview", bundle: .module).foregroundStyle(InterfaceTheme.text)
                    }
                }
                if !isNew {
                    Section {
                        Button(String(localized: "Delete tag", bundle: .module), role: .destructive) {
                            confirmingDelete = true
                        }
                    } footer: {
                        Text("Deleting a tag removes it from every note. Note content is unchanged.", bundle: .module)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle(Text(isNew ? String(localized: "New tag", bundle: .module) : String(localized: "Edit tag", bundle: .module)))
            .navigationBarTitleDisplayMode(.inline)
            .tint(InterfaceTheme.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) {
                        do {
                            try update(LibraryTag(id: tag.id, name: name, colorHex: colorHex))
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog(
                String(localized: "Delete this tag from every note?", bundle: .module),
                isPresented: $confirmingDelete, titleVisibility: .visible
            ) {
                Button(String(localized: "Delete tag", bundle: .module), role: .destructive) {
                    delete()
                    dismiss()
                }
                Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
            }
            .task { if isNew { nameFocused = true } }
        }
    }

    private var color: Binding<Color> {
        Binding(
            get: { TagSwatch.color(hex: colorHex) },
            set: { value in
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                guard UIColor(value).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                    error = String(localized: "This color couldn't be read. Choose another color.", bundle: .module)
                    return
                }
                colorHex = String(
                    format: "#%02X%02X%02X", Int((min(1, max(0, red)) * 255).rounded()),
                    Int((min(1, max(0, green)) * 255).rounded()), Int((min(1, max(0, blue)) * 255).rounded())
                )
            }
        )
    }
}
#endif
