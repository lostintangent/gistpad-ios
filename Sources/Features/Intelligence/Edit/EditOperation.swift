import Foundation

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
        in snapshot: FileSnapshot, pass: ModelPass, scope: NSRange
    ) throws -> [(Proposal.Change, NSRange)] {
        let source = snapshot.source as NSString
        switch self {
        case .setTaskStates(let ids, let isComplete):
            guard ids.map({ !$0.isEmpty && Set($0).count == $0.count }) ?? true
            else { throw IntelligenceError.invalidResponse }
            let selected =
                ids.map { identifiers in
                    pass.tasks.filter { identifiers.contains($0.id) }
                } ?? pass.tasks
            guard ids == nil || selected.count == ids?.count else {
                throw IntelligenceError.invalidResponse
            }
            return selected.filter { $0.isComplete != isComplete }.map { task in
                (
                    Proposal.Change(
                        quote: source.substring(with: task.range),
                        replacement: isComplete ? "[x]" : "[ ]",
                        reason: isComplete
                            ? String(localized: "Mark this task complete.", bundle: .module)
                            : String(localized: "Mark this task incomplete.", bundle: .module)),
                    task.range
                )
            }
        case .deleteTasks(let ids):
            guard !ids.isEmpty, Set(ids).count == ids.count,
                ids.allSatisfy({ id in pass.tasks.contains { $0.id == id } })
            else { throw IntelligenceError.invalidEdit }
            return pass.tasks.filter { ids.contains($0.id) }.map { task in
                let line = source.lineRange(for: task.range)
                return (
                    Proposal.Change(
                        quote: source.substring(with: line), replacement: "",
                        reason: String(localized: "Remove this task.", bundle: .module)), line
                )
            }
        case .insertTask(let listID, let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !text.contains(where: \.isNewline)
            else { throw IntelligenceError.invalidEdit }
            let last = pass.tasks.last { $0.listID == listID }
            guard last != nil || (listID == 0 && snapshot.tasks.isEmpty) else {
                throw IntelligenceError.invalidEdit
            }
            let newline = snapshot.source.contains("\r\n") ? "\r\n" : "\n"
            let offset: Int
            let insertion: String
            if let last {
                let line = source.lineRange(for: last.range)
                offset = NSMaxRange(line)
                let prefix = source.substring(
                    with: NSRange(location: line.location, length: last.range.location - line.location))
                let lineText = source.substring(with: line)
                let ending = lineText.last.flatMap { $0.isNewline ? String($0) : nil }
                let taskNewline = ending ?? newline
                insertion =
                    (ending == nil ? taskNewline : "") + prefix + "[ ] " + text
                    + (ending == nil ? "" : taskNewline)
            } else {
                offset = source.length
                insertion =
                    (source.length == 0 || snapshot.source.last?.isNewline == true ? "" : newline)
                    + "- [ ] " + text + newline
            }
            return [
                (
                    Proposal.Change(
                        quote: "", replacement: insertion,
                        reason: String(localized: "Add this task.", bundle: .module)),
                    NSRange(location: offset, length: 0)
                )
            ]
        case .rewriteRegion(let relative, let revised):
            guard relative.location >= 0, NSMaxRange(relative) <= scope.length
            else { throw IntelligenceError.invalidResponse }
            return try Proposal.Change.lineChanges(
                in: snapshot.source,
                visible: NSRange(location: scope.location + relative.location, length: relative.length),
                revised: revised)
        case .replaceRegion(let relative, let change):
            guard relative.location >= 0, relative.length > 0,
                NSMaxRange(relative) <= scope.length,
                change.replacement != nil,
                change.quote.utf8.elementsEqual((pass.source as NSString).substring(with: relative).utf8)
            else { throw IntelligenceError.invalidResponse }
            return [(change, NSRange(location: scope.location + relative.location, length: relative.length))]
        }
    }
}
