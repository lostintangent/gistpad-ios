import Comments
import Editor
import Model
import Observation
import Screens
import Store
import SwiftUI

/// Comments for the open gist: one in-memory `CommentsModel`, dropped when another gist opens.
@Observable
final class CommentsState {
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
    /// Asks the conversation to show the selected thread again.
    private(set) var revealRevision: UInt64 = 0
    /// Where the preview scrolls to show a thread's passage.
    private(set) var previewPosition = ScrollPosition(idType: Int64.self)
    /// The threads the preview finds a passage for.
    private var previewMatchedThreadIDs: Set<Int64>?
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

    /// The threads whose passages the current file mode finds.
    var matchedThreadIDs: Set<Int64>? {
        fileMode == .edit ? fileEditor?.editor.matchedThreadIDs : previewMatchedThreadIDs
    }

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
        previewMatchedThreadIDs = nil
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

    /// The file's comments, or nil when it can't have any.
    func documentComments(for fileEditor: GistFileEditor) -> DocumentComments? {
        guard Self.supports(fileEditor.file) else { return nil }
        guard matches(fileEditor.file), let model else { return DocumentComments() }
        return DocumentComments(
            quotes: model.threads.compactMap(\.quotedPassage), selectedThreadID: selectedThreadID,
            showsAll: showsInlineComments)
    }

    /// Opens the threads under a passage tapped in one mode, or lets you choose when they overlap.
    func openThreads(_ ids: [Int64], in fileEditor: GistFileEditor, origin: FileMode) {
        guard self.fileEditor === fileEditor else { return }
        if ids.count == 1, let id = ids.first {
            open(for: fileEditor, origin: origin, threadID: id)
        } else {
            fileMode = origin
            overlappingThreadIDs = ids
        }
    }

    /// Starts a thread quoting text selected in one mode.
    func addComment(quoting quote: String, in fileEditor: GistFileEditor, origin: FileMode) {
        guard self.fileEditor === fileEditor else { return }
        open(for: fileEditor, origin: origin, quote: quote)
    }

    /// Records which threads the preview finds a passage for. The editor keeps its own.
    func matchedInPreview(_ ids: Set<Int64>, in fileEditor: GistFileEditor) {
        guard self.fileEditor === fileEditor else { return }
        previewMatchedThreadIDs = ids
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
        if let threadID { reveal(threadID) }
        isPresented = true
        guard let model = prepare() else { return }
        if let quote {
            model.beginQuote(quote, filename: next.file.filename)
            isComposerFocused = true
        }
        if opening || model.comments == nil { Task { await model.refresh() } }
    }

    func hide() {
        isPresented = false
        selectedThreadID = nil
        overlappingThreadIDs = []
        isComposerFocused = false
    }

    /// Follows a failure's one fix: signs in to GitHub again when it asks to, then tries again.
    func recover(from failure: Failure, retry: () async -> Void) async {
        if failure.action == .reconnect { await app.reconnect() }
        await retry()
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
        reveal(id)
    }

    /// Brings a thread into view in the conversation and in the file's current mode.
    private func reveal(_ threadID: Int64) {
        revealRevision &+= 1
        if fileMode == .edit {
            fileEditor?.editor.revealThread(threadID)
        } else {
            previewPosition.scrollTo(id: threadID)
        }
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
        previewMatchedThreadIDs = nil
    }

    private func isReady(for file: GistFile) -> Bool {
        app.account?.id == file.accountID && !app.phase.isChangingAccount
    }

    private func prepare() -> CommentsModel? {
        if model == nil, scope != nil, let gist = fileEditor?.file.gist {
            model = app.comments(for: gist)
        }
        return model
    }
}
