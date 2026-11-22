#if os(iOS)
import Appearance
import Store
import SwiftUI

public struct TagEditor: View {
    private let save: (@MainActor ([GistPadPreferences.Change]) async throws -> Void)?
    @State private var draft: TagEditorDraft
    @State private var query = ""
    @State private var editingTag: Tag?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var confirmingDiscard = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        gistID: String, tags: [Tag], selectedTagIDs: Set<String>,
        save: (@MainActor ([GistPadPreferences.Change]) async throws -> Void)? = nil
    ) {
        self.save = save
        _draft = State(initialValue: TagEditorDraft(gistID: gistID, tags: tags, selectedTagIDs: selectedTagIDs))
    }

    public var body: some View {
        NavigationStack {
            List {
                if let saveError {
                    Section {
                        Label(String(localized: "Couldn’t save your tags.", bundle: .module), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.primary)
                        Button(String(localized: "Try Again", bundle: .module), action: commit)
                    } footer: {
                        Text(verbatim: saveError)
                    }
                }
                Section {
                    ForEach(listedTags) { tag in
                        if save == nil {
                            TagChoice(tag: tag, isSelected: true)
                        } else {
                            editableRow(tag)
                        }
                    }
                    if listedTags.isEmpty {
                        Text(
                            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? String(localized: "No tags yet.", bundle: .module)
                                : String(localized: "No matching tags.", bundle: .module))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("tag-empty")
                    }
                }
                .listSectionSeparator(.hidden)
            }
            .listStyle(.plain)
            .navigationTitle(Text("Tags", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text("Search tags", bundle: .module))
            .toolbar { toolbar }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving || !draft.edits.isEmpty)
            .sheet(item: $editingTag) { tag in
                TagEditForm(
                    tag: tag, isNew: !draft.tags.contains(where: { $0.id == tag.id }),
                    update: { draft.upsert($0) },
                    delete: { draft.delete(tag) }
                )
            }
            .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
            .presentationDragIndicator(.visible)
            .confirmationDialog(
                String(localized: "Discard tag changes?", bundle: .module),
                isPresented: $confirmingDiscard, titleVisibility: .visible
            ) {
                Button(String(localized: "Discard Changes", bundle: .module), role: .destructive) { dismiss() }
                Button(String(localized: "Keep Editing", bundle: .module), role: .cancel) {}
            }
        }
    }

    /// A sheet that can't save lists only the gist's own tags.
    private var listedTags: [Tag] {
        let tags = draft.tags.matching(query)
        return save == nil ? tags.filter { draft.selectedTagIDs.contains($0.id) } : tags
    }

    private func editableRow(_ tag: Tag) -> some View {
        TagChoice(tag: tag, isSelected: draft.selectedTagIDs.contains(tag.id)) {
            draft.selectedTagIDs.formSymmetricDifference([tag.id])
        }
        .accessibilityIdentifier("tag-choice-\(tag.id)")
        .accessibilityAction(named: Text("Edit Tag \(tag.name)", bundle: .module)) { editingTag = tag }
        .contextMenu {
            Button(String(localized: "Edit Tag", bundle: .module), systemImage: "pencil") { editingTag = tag }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(String(localized: "Edit Tag", bundle: .module), systemImage: "pencil") { editingTag = tag }
                .labelStyle(.iconOnly)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if save != nil {
                Button(role: .cancel) {
                    if draft.edits.isEmpty { dismiss() } else { confirmingDiscard = true }
                }
            } else {
                Button(role: .close) { dismiss() }
            }
        }
        DefaultToolbarItem(kind: .search, placement: .bottomBar)
        if save != nil {
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button(String(localized: "New Tag", bundle: .module), systemImage: "plus") {
                    editingTag = Tag(id: UUID().uuidString, name: "")
                }
                .accessibilityIdentifier("tag-create")
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            if isSaving {
                ProgressView(String(localized: "Saving tags", bundle: .module))
            } else if save != nil {
                Button(role: .confirm, action: commit)
                    .accessibilityIdentifier("tag-save")
            }
        }
    }

    private func commit() {
        guard let save, !draft.edits.isEmpty else { dismiss(); return }
        guard !isSaving else { return }
        let edits = draft.edits
        isSaving = true
        saveError = nil
        Task {
            defer { isSaving = false }
            do {
                try await save(edits)
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

private struct TagEditForm: View {
    let tag: Tag
    let isNew: Bool
    let update: (Tag) -> Bool
    let delete: () -> Void
    @State private var name: String
    @State private var colorHex: String?
    @State private var error: String?
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.self) private var environment

    init(
        tag: Tag, isNew: Bool, update: @escaping (Tag) -> Bool,
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
                        Button(String(localized: "Use Default Color", bundle: .module)) { colorHex = nil }
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.primary)
                    }
                }
                if !name.isEmpty {
                    Section {
                        TagLabel(tag: Tag(id: tag.id, name: name, colorHex: colorHex))
                    } header: {
                        Text("Preview", bundle: .module)
                    }
                }
                if !isNew {
                    Section {
                        Button(String(localized: "Delete Tag", bundle: .module), role: .destructive) {
                            confirmingDelete = true
                        }
                    } footer: {
                        Text("Deleting a tag removes it from every gist. Files are unchanged.", bundle: .module)
                    }
                }
            }
            .navigationTitle(Text(isNew ? String(localized: "New Tag", bundle: .module) : String(localized: "Edit Tag", bundle: .module)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        if update(Tag(id: tag.id, name: name, colorHex: colorHex)) {
                            dismiss()
                        } else {
                            error = String(localized: "A tag with this name already exists.", bundle: .module)
                        }
                    }
                    .accessibilityIdentifier("tag-form-save")
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog(
                String(localized: "Delete this tag from every gist?", bundle: .module),
                isPresented: $confirmingDelete, titleVisibility: .visible
            ) {
                Button(String(localized: "Delete Tag", bundle: .module), role: .destructive) {
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
            get: { RGBColor(tagHex: colorHex)?.color ?? .secondary },
            set: { colorHex = RGBColor($0.resolve(in: environment)).hex })
    }
}
#endif
