import Foundation
import Markdown

/// An edit as the model describes it, in task IDs and ranges within its pass.
package enum EditOperation: Sendable {
    case setTaskStates(ids: [Int]?, isComplete: Bool)
    case insertTask(listID: Int, text: String)
    case deleteTasks(ids: [Int])
    /// A region as the model revised it, using a UTF-16 range relative to the model pass.
    /// The app compares it line by line.
    case rewriteRegion(NSRange, revised: String)
    case replaceRegion(NSRange, Proposal.Change)

    /// The changes this makes to the note, each with the range it may change. `scope` is the part
    /// of the note the pass showed the model.
    func changes(
        in note: MarkdownDocument, pass: ModelPass, scope: NSRange
    ) throws -> [(Proposal.Change, NSRange)] {
        switch self {
        case .setTaskStates(let ids, let isComplete):
            guard ids.map({ !$0.isEmpty && Set($0).count == $0.count }) ?? true
            else { throw IntelligenceError.invalidResponse }
            let document = MarkdownDocument(pass.source)
            let tasks = document.taskLists.flatMap(\.self)
            let selected = ids.map { ids in tasks.indices.filter { ids.contains($0 + 1) }.map { tasks[$0] } } ?? tasks
            guard ids == nil || selected.count == ids?.count else {
                throw IntelligenceError.invalidResponse
            }
            let reason =
                isComplete
                ? String(localized: "Mark this task complete.", bundle: .module)
                : String(localized: "Mark this task incomplete.", bundle: .module)
            return selected.filter { $0.isChecked != isComplete }.compactMap { task in
                task.box.flatMap { document.edit(togglingTaskAt: $0.location) }?
                    .change(at: scope.location, reason: reason)
            }
        case .deleteTasks(let ids):
            let tasks = MarkdownDocument(pass.source).taskLists.flatMap(\.self)
            guard !ids.isEmpty, Set(ids).count == ids.count, ids.allSatisfy({ tasks.indices.contains($0 - 1) })
            else { throw IntelligenceError.invalidEdit }
            let source = pass.source as NSString
            return tasks.indices.filter { ids.contains($0 + 1) }.map { index in
                let line = source.lineRange(for: tasks[index].range)
                return (
                    Proposal.Change(
                        quote: source.substring(with: line), replacement: "",
                        reason: String(localized: "Remove this task.", bundle: .module)),
                    NSRange(location: scope.location + line.location, length: line.length)
                )
            }
        case .insertTask(let listID, let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !text.contains(where: \.isNewline)
            else { throw IntelligenceError.invalidEdit }
            let reason = String(localized: "Add this task.", bundle: .module)
            if listID == 0, note.tasks.isEmpty {
                return [note.edit(appendingTasks: text).change(at: 0, reason: reason)]
            }
            let document = MarkdownDocument(pass.source)
            let lists = document.taskLists
            // A quoted list can't continue, because the document leaves quoted items alone.
            guard lists.indices.contains(listID - 1), let last = lists[listID - 1].last,
                let edit = document.edit(
                    continuingListAt: NSRange(location: NSMaxRange(last.range), length: 0), with: text)
            else { throw IntelligenceError.invalidEdit }
            return [edit.change(at: scope.location, reason: reason)]
        case .rewriteRegion(let relative, let revised):
            guard relative.location >= 0, NSMaxRange(relative) <= scope.length
            else { throw IntelligenceError.invalidResponse }
            return try Proposal.Change.lineChanges(
                in: note.text,
                visible: NSRange(location: scope.location + relative.location, length: relative.length),
                revised: revised)
        case .replaceRegion(let relative, let change):
            guard relative.location >= 0, relative.length > 0,
                NSMaxRange(relative) <= scope.length,
                change.quote.utf8.elementsEqual((pass.source as NSString).substring(with: relative).utf8)
            else { throw IntelligenceError.invalidResponse }
            return [(change, NSRange(location: scope.location + relative.location, length: relative.length))]
        }
    }
}
