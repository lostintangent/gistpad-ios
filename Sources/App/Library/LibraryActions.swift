import Foundation
import Model
import Screens
import Store

extension LibraryActions {
    /// The Library's verbs, run by the model. The root view passes the ones that move navigation:
    /// opening a row or its comments, opening Today and showing Settings.
    init(
        model: GistPadModel, undoManager: UndoManager?,
        select: @escaping (String) -> Void, openComments: @escaping (String) -> Void,
        today: @escaping @MainActor () -> Void, settings: @escaping () -> Void
    ) {
        var actions = LibraryActions()
        actions.refresh = { await model.refresh() }
        actions.create = { Task { await model.open(.new) } }
        actions.today = today
        actions.select = select
        actions.openComments = openComments
        actions.settings = settings
        actions.reconnect = { Task { await model.reconnect() } }
        actions.recoverStatus = {
            Task {
                if model.refreshFailure?.action == .reconnect {
                    await model.reconnect()
                } else {
                    await model.refresh()
                }
            }
        }
        // An alert names the row as the Library shows it.
        let rowName = { (rowID: String) in
            model.state.gists.first { $0.id == rowID }?
                .displayTitle(now: .now, locale: .current, calendar: .current) ?? ""
        }
        actions.togglePin = { rowID in
            let name = rowName(rowID)
            guard let account = model.account, let id = model.gistID(forRow: rowID) else {
                model.failure = Failure(
                    String(localized: "You can pin this gist after it publishes."),
                    title: String(localized: "Couldn’t Pin “\(name)”"))
                return
            }
            let pinned = !account.preferences.pinnedGists.contains(id)
            let title = pinned
                ? String(localized: "Couldn’t Pin “\(name)”")
                : String(localized: "Couldn’t Unpin “\(name)”")
            model.run(titled: title) {
                try await model.updatePreferences([.setPinned(gistID: id, pinned: pinned)])
            }
        }
        actions.toggleArchive = { rowID in
            let name = rowName(rowID)
            guard let id = model.gistID(forRow: rowID),
                let gist = model.gistCache?.gists.first(where: { $0.id == id })
            else {
                model.failure = Failure(
                    String(localized: "You can archive this gist after it publishes."),
                    title: String(localized: "Couldn’t Archive “\(name)”"))
                return
            }
            model.setArchived(!gist.isArchived, gistID: id, name: name, undoManager: undoManager)
        }
        actions.delete = { rowID in
            guard let deletion = model.deletion(forRow: rowID) else { return }
            model.run(titled: String(localized: "Couldn’t Delete “\(rowName(rowID))”")) {
                try await model.delete(deletion)
            }
        }
        self = actions
    }
}
