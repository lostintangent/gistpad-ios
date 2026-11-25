import Foundation

extension MarkdownDocument {
    /// Adds `text` to the end of the note as its own paragraph, after a blank line.
    public func edit(appendingParagraph text: String) -> MarkdownEdit {
        appending(text.trimmingCharacters(in: .newlines), after: 2)
    }

    /// Adds an open task for each nonblank line of `text`, on the lines after the note's last.
    public func edit(appendingTasks text: String) -> MarkdownEdit {
        let tasks = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return appending(tasks.map { "- [ ] " + $0 }.joined(separator: lineBreak), after: 1)
    }

    /// `lines` ending in a line break, after the line breaks that leave `breaks` of them between
    /// the note's text and the new lines. An empty note needs none.
    private func appending(_ lines: String, after breaks: Int) -> MarkdownEdit {
        var end = source.length
        var trailing = 0
        while trailing < breaks, end > 0, [10, 13].contains(source.character(at: end - 1)) {
            let pair = end > 1 && source.character(at: end - 2) == 13 && source.character(at: end - 1) == 10
            end -= pair ? 2 : 1
            trailing += 1
        }
        let separator = source.length == 0 ? "" : String(repeating: lineBreak, count: breaks - trailing)
        return edit(replacing: NSRange(location: source.length, length: 0), with: separator + lines + lineBreak)
    }
}
