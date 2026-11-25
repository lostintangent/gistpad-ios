import Foundation
import Markdown

extension MarkdownDocument {
    func text(in range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }

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

    /// The list items a request to move one between sections names, each with the heading line above it.
    // Platform gap: AFM Core names a move's target less reliably and more slowly than this English
    // pattern. Remove when a model-extracted target passes the Edit eval.
    func listItems(movedBy instruction: String) -> [(item: Block, heading: String)] {
        guard
            let target = instruction.firstMatch(of: /(?i)\b(?:move|relocate)\s+(.+?)\s+from\s+.+?\s+to\s+/)?.1
        else { return [] }
        var heading = ""
        return blocks.compactMap { block in
            let text = text(in: block.range)
            if block.kind == .heading { heading = text }
            guard block.kind == .listItem, text.localizedCaseInsensitiveContains(target) else { return nil }
            return (block, heading)
        }
    }
}

extension MarkdownEdit {
    /// This edit as a change to the note, whose text from `offset` on is the edited document's.
    func change(at offset: Int, reason: String) -> (Proposal.Change, NSRange) {
        (
            Proposal.Change(quote: document.text(in: range), replacement: replacement, reason: reason),
            NSRange(location: offset + range.location, length: range.length)
        )
    }
}
