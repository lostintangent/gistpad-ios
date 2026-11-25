import Editor
import Intelligence
import Model
import Store
import SwiftUI

/// The file Intelligence opens on. A passage the sheet shows opens in the editor once it closes.
final class IntelligenceTarget: Identifiable {
    let editor: MarkdownEditor
    let title: String
    let canEdit: Bool
    let wasEditing: Bool
    var passage: NSRange?
    private let revealSource: @MainActor (NSRange) -> Void

    /// Throws while the editor is unsettled, as when the keyboard is composing.
    convenience init(
        _ fileEditor: GistFileEditor, model: GistPadModel,
        showEditor: @escaping @MainActor () -> Void
    ) throws(MarkdownEditor.Failure) {
        let editor = fileEditor.editor
        guard editor.isSettled else { throw .unsettled }
        self.init(
            editor: editor, title: fileEditor.details.title, canEdit: fileEditor.details.isOwned
        ) { range in
            guard fileEditor.details.isOwned else {
                model.failure = Failure(
                    String(localized: "This gist is read-only, so this passage can’t open in Edit."),
                    title: String(localized: "Couldn’t Show in File"))
                return
            }
            let generation = editor.generation
            showEditor()
            fileEditor.mode = .edit
            Task {
                await Task.yield()
                guard editor.generation == generation else {
                    model.failure = Failure(
                        String(localized: "This passage is no longer in the file."),
                        title: String(localized: "Couldn’t Show in File"))
                    return
                }
                editor.select(range)
            }
        }
    }

    init(
        editor: MarkdownEditor, title: String, canEdit: Bool,
        revealSource: @escaping @MainActor (NSRange) -> Void
    ) {
        self.editor = editor
        self.title = title
        self.canEdit = canEdit
        self.revealSource = revealSource
        wasEditing = editor.isEditing
    }

    /// Opens the passage the sheet showed, or returns to the editor you were typing in.
    fileprivate func closed() {
        if let passage {
            revealSource(passage)
        } else if wasEditing {
            editor.focus()
        }
    }
}

extension View {
    func intelligenceSheet(_ target: Binding<IntelligenceTarget?>) -> some View {
        modifier(IntelligenceSheetModifier(target: target))
    }
}

private struct IntelligenceSheetModifier: ViewModifier {
    @Binding var target: IntelligenceTarget?
    /// The target the sheet opened with, still here when it closes.
    @State private var shown: IntelligenceTarget?

    func body(content: Content) -> some View {
        content
            .onChange(of: target?.id) {
                guard let target else { return }
                target.editor.endEditing()
                shown = target
            }
            .sheet(item: $target, onDismiss: dismissed) { target in
                IntelligenceSheet(
                    editor: target.editor, title: target.title, canEdit: target.canEdit,
                    revealSource: { target.passage = $0 }
                )
            }
    }

    private func dismissed() {
        shown?.closed()
        shown = nil
    }
}
