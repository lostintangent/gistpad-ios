import Comments
import Editor
import Screens
import Model
import Observation
import SwiftUI

/// Comments for the open gist: one in-memory `CommentsModel`, dropped when another gist opens.
@Observable
final class CommentsPresentation {
    struct Scope: Hashable {
        let accountID: UUID
        let gistID: String
    }

    /// What `track(_:)` reads, so a file's tracking restarts when any of it changes.
    struct Tracking: Hashable {
        let editorID: UUID
        let scope: Scope?
        let knownTotal: Int?
        let isReady: Bool
        let showsInlineComments: Bool
    }

    var isPresented = false
    private(set) var model: CommentsModel?
    var selectedThreadID: Int64?
    /// Asks the conversation and the file to show the selected thread again.
    private(set) var revealRevision: UInt64 = 0
    /// The threads each mode's surface finds a passage for.
    private var linkedThreadIDsByMode: [FileMode: Set<Int64>] = [:]
    var fileMode: FileMode = .preview
    var detent = PresentationDetent.medium
    var isComposerFocused = false
    var overlappingThreadIDs: [Int64] = []
    var requestedRowID: String?
    private(set) var scope: Scope?
    @ObservationIgnored let app: GistPadModel
    @ObservationIgnored private var fileEditor: GistFileEditor?
    @ObservationIgnored private var afterDismiss: (() -> Void)?
    @ObservationIgnored private var returnsToEditing = false

    init(app: GistPadModel) {
        self.app = app
    }

    /// The editor of the file Comments follows, once it's activated.
    var editorID: UUID? { fileEditor?.editor.id }

    /// The threads whose passages the current file mode links.
    var linkedThreadIDs: Set<Int64>? { linkedThreadIDsByMode[fileMode] }

    private var showsInlineComments: Bool {
        app.account?.preferences.booleanValue(.showInlineComments, default: true) ?? true
    }

    static func supports(_ file: GistFile) -> Bool {
        guard let gist = file.gist else { return false }
        return !gist.isDailyNote && !file.isDeletedOnGitHub
    }

    private static func scope(for file: GistFile) -> Scope? {
        guard supports(file), let gist = file.gist else { return nil }
        return .init(accountID: file.accountID, gistID: gist.id)
    }

    func matches(_ file: GistFile) -> Bool {
        guard let gistID = file.gist?.id else { return false }
        return scope == .init(accountID: file.accountID, gistID: gistID)
    }

    func activate(_ next: GistFileEditor) {
        let nextScope = Self.scope(for: next.file)
        guard fileEditor !== next || scope != nextScope else { return }
        if scope != nextScope {
            hide()
            model = nil
        }
        scope = nextScope
        fileEditor = next
        linkedThreadIDsByMode = [:]
    }

    func tracking(_ fileEditor: GistFileEditor) -> Tracking {
        .init(
            editorID: fileEditor.editor.id, scope: Self.scope(for: fileEditor.file),
            knownTotal: fileEditor.file.gist?.commentCount, isReady: isReady(for: fileEditor.file),
            showsInlineComments: showsInlineComments)
    }

    /// Follows the open file, loading its comments when passages show inline.
    func track(_ fileEditor: GistFileEditor) async {
        guard isReady(for: fileEditor.file) else { return }
        activate(fileEditor)
        guard showsInlineComments else { return }
        await prepare()?.refresh()
    }

    /// The file's passage highlights in one mode, and what tapping, linking and adding one does.
    func highlights(
        for fileEditor: GistFileEditor, origin: FileMode
    ) -> (configuration: CommentHighlightConfiguration, actions: CommentHighlightActions?) {
        guard Self.supports(fileEditor.file) else { return (.init(), nil) }
        var configuration = CommentHighlightConfiguration()
        if matches(fileEditor.file), let model {
            configuration = .init(
                quotes: model.threads.compactMap(\.quotedPassage), selectedThreadID: selectedThreadID,
                revealRevision: revealRevision, showsInlineComments: showsInlineComments)
        }
        let isCurrent = { self.fileEditor === fileEditor }
        let actions = CommentHighlightActions(
            open: { ids in
                guard isCurrent() else { return }
                if ids.count == 1, let id = ids.first {
                    self.open(for: fileEditor, origin: origin, threadID: id)
                } else {
                    self.fileMode = origin
                    self.overlappingThreadIDs = ids
                }
            },
            linked: { ids in
                guard isCurrent() else { return }
                self.linkedThreadIDsByMode[origin] = ids
            },
            add: { selection in
                guard isCurrent() else { return }
                self.open(for: fileEditor, origin: origin, quote: selection)
            })
        return (configuration, actions)
    }

    func open(
        for next: GistFileEditor, origin: FileMode? = nil,
        threadID: Int64? = nil, quote: String? = nil
    ) {
        guard fileEditor === next, Self.supports(next.file) else { return }
        let opening = !isPresented
        if opening {
            returnsToEditing = next.editor.isEditing
            next.editor.endEditing()
            fileMode = origin ?? (returnsToEditing ? .edit : next.mode)
            if fileMode == .split { fileMode = .preview }
        } else if let origin {
            fileMode = origin
        }
        if !next.details.isOwned { fileMode = .preview }
        detent = quote == nil ? .medium : .large
        selectedThreadID = threadID
        if threadID != nil { revealRevision &+= 1 }
        isPresented = true
        let filename = next.file.filename
        Task {
            guard let model = await prepare() else { return }
            if let quote {
                model.beginQuote(quote, filename: filename)
                isComposerFocused = true
            }
            if opening || model.comments == nil { await model.refresh() }
        }
    }

    func hide() {
        isPresented = false
        selectedThreadID = nil
        overlappingThreadIDs = []
        isComposerFocused = false
    }

    func focusComposer() {
        detent = .large
        isComposerFocused = true
    }

    /// Shows a thread's passage in the file, out from under the keyboard and a full-height sheet.
    func revealPassage(_ id: Int64) {
        selectedThreadID = id
        isComposerFocused = false
        detent = .medium
        revealRevision &+= 1
    }

    func didDismiss() {
        guard !isPresented else { return }
        hide()
        if let afterDismiss {
            self.afterDismiss = nil
            afterDismiss()
            return
        }
        let resumesEditing = returnsToEditing
        returnsToEditing = false
        if resumesEditing { fileEditor?.editor.focus() }
    }

    func performAfterClosing(_ action: @escaping () -> Void) {
        guard isPresented else { action(); return }
        afterDismiss = action
        hide()
    }

    func reset() {
        hide()
        afterDismiss = nil
        returnsToEditing = false
        model = nil
        fileEditor = nil
        scope = nil
        requestedRowID = nil
        linkedThreadIDsByMode = [:]
    }

    private func isReady(for file: GistFile) -> Bool {
        app.account?.id == file.accountID && !app.phase.isChangingAccount
    }

    private func prepare() async -> CommentsModel? {
        if let model { return model }
        // Only an account change stops the client, and that resets Comments.
        guard let scope, let gist = fileEditor?.file.gist,
            let created = try? await app.comments(for: gist), self.scope == scope
        else { return nil }
        if model == nil { model = created }
        return model
    }
}
