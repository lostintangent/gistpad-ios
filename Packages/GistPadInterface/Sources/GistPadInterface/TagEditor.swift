#if os(iOS)
import GistPadAppearance
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.personalAccent) private var personalAccent
    @ScaledMetric(relativeTo: .body) private var swatchSize: CGFloat = 12

    public init(
        tags: [LibraryTag], selectedTagIDs: Set<String>,
        save: (@MainActor ([TagEdit]) async throws -> Void)? = nil
    ) {
        self.save = save
        _draft = State(initialValue: TagEditorDraft(tags: tags, selectedTagIDs: selectedTagIDs))
    }

    #if DEBUG
    public func captureQuery(_ value: String) -> Self {
        var editor = self
        editor._query = State(initialValue: value)
        return editor
    }

    public func captureEditingTag(_ tag: LibraryTag?) -> Self {
        var editor = self
        editor._editingTag = State(initialValue: tag)
        return editor
    }
    #endif

    public var body: some View {
        NavigationStack {
            List {
                if let saveError {
                    Section {
                        Label(String(localized: "Couldn't finish saving tags.", bundle: .module), systemImage: "exclamationmark.circle")
                        Text(verbatim: saveError).font(.subheadline)
                        Text("Some changes may already be saved. Retry to finish applying your choices.", bundle: .module)
                            .font(.footnote)
                        Button(String(localized: "Retry", bundle: .module), action: commit)
                            .tint(.primary)
                    }
                    .foregroundStyle(.primary)
                }
                Section {
                    ForEach(save == nil ? selectedTags : matchingTags) { tag in
                        if save == nil {
                            tagRow(tag)
                        } else {
                            editableRow(tag)
                        }
                    }
                    if (save == nil ? selectedTags : matchingTags).isEmpty {
                        Text(
                            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? String(localized: "No tags yet.", bundle: .module)
                                : String(localized: "No matching tags.", bundle: .module))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("tag-empty")
                            .captureFrame("tag-empty")
                    }
                    if save != nil {
                        Button {
                            editingTag = LibraryTag(id: UUID().uuidString, name: "")
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus")
                                    .foregroundStyle(.primary)
                                    .frame(width: min(swatchSize, 24))
                                Text("New Tag", bundle: .module)
                                    .foregroundStyle(.primary)
                            }
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .accessibilityIdentifier("tag-create")
                        .captureFrame("tag-create")
                    }
                } footer: {
                    Text("Tags apply to every file in this note.", bundle: .module)
                        .foregroundStyle(.secondary)
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
                    update: { try draft.upsert($0) },
                    delete: { draft.delete(tag) }
                )
                .personalAccent(savedHex: personalAccent.savedHex)
            }
            .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
            .presentationDragIndicator(.visible)
            .confirmationDialog(
                draft.hasAttemptedChanges
                    ? String(localized: "Close without retrying?", bundle: .module)
                    : String(localized: "Discard tag changes?", bundle: .module),
                isPresented: $confirmingDiscard, titleVisibility: .visible
            ) {
                Button(
                    draft.hasAttemptedChanges
                        ? String(localized: "Close", bundle: .module)
                        : String(localized: "Discard Changes", bundle: .module),
                    role: .destructive
                ) { dismiss() }
                Button(String(localized: "Keep Editing", bundle: .module), role: .cancel) {}
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
            tagRow(tag)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tag-choice-\(tag.id)")
        .captureFrame("tag-choice-\(tag.id)")
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .accessibilityAddTraits(draft.selectedTagIDs.contains(tag.id) ? .isSelected : [])
        .accessibilityAction(named: Text("Edit Tag \(tag.name)", bundle: .module)) { editingTag = tag }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: draft.selectedTagIDs.contains(tag.id))
        .contextMenu {
            Button(String(localized: "Edit Tag…", bundle: .module), systemImage: "pencil") { editingTag = tag }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(String(localized: "Edit Tag…", bundle: .module), systemImage: "pencil") { editingTag = tag }
        }
    }

    private func tagRow(_ tag: LibraryTag) -> some View {
        HStack(spacing: 12) {
            TagSwatch(hex: tag.colorHex, size: min(swatchSize, 24))
                .accessibilityHidden(true)
            Text(verbatim: tag.name)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if draft.selectedTagIDs.contains(tag.id) {
                Image(systemName: "checkmark")
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if save != nil {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .cancel) {
                    if draft.edits.isEmpty { dismiss() } else { confirmingDiscard = true }
                }
                .accessibilityLabel(Text("Cancel", bundle: .module))
                .tint(.primary)
            }
        }
        DefaultToolbarItem(kind: .search, placement: .bottomBar)
        ToolbarItem(placement: .confirmationAction) {
            if isSaving {
                ProgressView(String(localized: "Saving tags", bundle: .module))
            } else if save != nil {
                Button(String(localized: "Save", bundle: .module), role: .confirm, action: commit)
                    .buttonStyle(.glassProminent)
                    .tint(Color(uiColor: .label))
                    .accessibilityLabel(Text("Save Tags", bundle: .module))
                    .accessibilityIdentifier("tag-save")
            } else {
                Button(role: .close) { dismiss() }
                    .accessibilityLabel(Text("Close", bundle: .module))
                    .tint(.primary)
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
                        Button(String(localized: "Use Default Color", bundle: .module)) { colorHex = nil }
                            .tint(.primary)
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
                        Button(String(localized: "Delete Tag", bundle: .module), role: .destructive) {
                            confirmingDelete = true
                        }
                    } footer: {
                        Text("Deleting a tag removes it from every note. Note content is unchanged.", bundle: .module)
                            .foregroundStyle(InterfaceTheme.text)
                    }
                }
            }
            .navigationTitle(Text(isNew ? String(localized: "New Tag", bundle: .module) : String(localized: "Edit Tag", bundle: .module)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                        .accessibilityLabel(Text("Cancel", bundle: .module))
                        .tint(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        do {
                            try update(LibraryTag(id: tag.id, name: name, colorHex: colorHex))
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Color(uiColor: .label))
                    .accessibilityLabel(Text("Save Tag", bundle: .module))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog(
                String(localized: "Delete this tag from every note?", bundle: .module),
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
