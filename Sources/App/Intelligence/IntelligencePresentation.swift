import Editor
import Intelligence
import Markdown
import Model
import Observation
import Store
import SwiftUI
import UIKit

@Observable
final class IntelligencePresentation {
    var target: Target?
    private var retainedTarget: Target?

    /// Opens Intelligence on the file. A passage the sheet shows opens in the editor once it closes.
    func present(
        _ fileEditor: GistFileEditor, model: GistPadModel,
        showEditor: @escaping @MainActor () -> Void
    ) {
        let editor = fileEditor.editor
        guard editor.isSettled else {
            model.failure = Failure(MarkdownEditor.Failure.unsettled)
            return
        }
        present(editor: editor, title: fileEditor.details.title) { range in
            guard fileEditor.details.isOwned else {
                model.failure = Failure(String(localized: "This gist is read-only, so this passage can’t open in Edit."))
                return
            }
            let generation = editor.generation
            showEditor()
            fileEditor.mode = .edit
            Task {
                await Task.yield()
                guard editor.generation == generation else {
                    model.failure = Failure(String(localized: "This passage is no longer in the file."))
                    return
                }
                editor.select(range)
            }
        }
    }

    func present(
        editor: MarkdownEditor, title: String,
        revealSource: @escaping @MainActor (NSRange) -> Void
    ) {
        let target = Target(editor: editor, title: title, revealSource: revealSource)
        retainedTarget = target
        editor.endEditing()
        self.target = target
    }

    func dismissed() {
        guard let target = retainedTarget else { return }
        retainedTarget = nil
        if let passage = target.passage {
            target.revealSource(passage)
            return
        }
        if target.wasEditing { target.editor.focus() }
    }

    final class Target: Identifiable {
        let editor: MarkdownEditor
        let title: String
        let revealSource: @MainActor (NSRange) -> Void
        let wasEditing: Bool
        var passage: NSRange?

        init(
            editor: MarkdownEditor, title: String,
            revealSource: @escaping @MainActor (NSRange) -> Void
        ) {
            self.editor = editor
            self.title = title
            self.revealSource = revealSource
            wasEditing = editor.isEditing
        }
    }
}

extension View {
    func intelligenceSheet(_ presentation: IntelligencePresentation) -> some View {
        modifier(IntelligenceSheetModifier(presentation: presentation))
    }
}

private struct IntelligenceSheetModifier: ViewModifier {
    @Bindable var presentation: IntelligencePresentation

    func body(content: Content) -> some View {
        content
            .sheet(item: $presentation.target, onDismiss: presentation.dismissed) { target in
                IntelligenceSheet(
                    editor: target.editor, title: target.title,
                    revealSource: { target.passage = $0 }
                )
            }
    }
}
