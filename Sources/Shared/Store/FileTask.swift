import Foundation

/// A Markdown task (`- [ ]` or `- [x]`) in any file. Ranges are UTF-16, so they index `NSString` and
/// `UITextView` directly.
public struct FileTask: Equatable, Hashable, Identifiable, Sendable {
    /// The text after the marker, trimmed.
    public let title: String
    public let isChecked: Bool
    /// The task's line, without its line break.
    public let lineRange: NSRange
    /// The `[ ]` or `[x]` brackets. Toggling replaces the one character inside them.
    public let markerRange: NSRange

    public var id: Int { markerRange.location }

    /// Every task in `markdown`, in order. This matches the web's `- \[[ x]\]` exactly, so tasks count
    /// anywhere on a line and inside code fences, and only a lowercase `x` is checked.
    public static func tasks(in markdown: String) -> [FileTask] {
        let source = markdown as NSString
        return expression.matches(in: markdown, range: NSRange(location: 0, length: source.length)).map { match in
            let marker = NSRange(location: match.range.location + 2, length: 3)
            var start = 0, contentsEnd = 0
            source.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: match.range)
            let titleStart = NSMaxRange(match.range)
            return FileTask(
                title: source.substring(with: NSRange(location: titleStart, length: contentsEnd - titleStart))
                    .trimmingCharacters(in: .whitespaces),
                isChecked: source.substring(with: marker) == "[x]",
                lineRange: NSRange(location: start, length: contentsEnd - start),
                markerRange: marker)
        }
    }

    private static let expression = try! NSRegularExpression(pattern: #"- \[[ x]\]"#)
}

public struct TaskProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public var remaining: Int { total - completed }

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }

    public init(markdown: String) {
        let tasks = FileTask.tasks(in: markdown)
        self.init(completed: tasks.count(where: \.isChecked), total: tasks.count)
    }
}
