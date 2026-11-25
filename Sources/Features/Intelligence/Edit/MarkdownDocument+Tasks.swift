import Foundation
import Markdown

extension MarkdownDocument {
    /// The note's tasks, in lists of tasks on consecutive lines. Edit numbers both from 1.
    var taskLists: [[ListItem]] {
        let source = text as NSString
        return tasks.reduce(into: []) { lists, task in
            if let last = lists.last?.last,
                NSMaxRange(source.lineRange(for: last.range)) == task.range.location
            {
                lists[lists.count - 1].append(task)
            } else {
                lists.append([task])
            }
        }
    }
}

extension MarkdownEdit {
    /// This edit as a change to the note, whose text from `offset` on is the edited document's.
    func change(at offset: Int, reason: String) -> (Proposal.Change, NSRange) {
        (
            Proposal.Change(
                quote: (document.text as NSString).substring(with: range), replacement: replacement,
                reason: reason),
            NSRange(location: offset + range.location, length: range.length)
        )
    }
}
