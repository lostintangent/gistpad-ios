/// The comments on a document: the passages its threads quote, and the thread you've selected.
/// A document without them can't have comments.
public struct DocumentComments: Equatable, Sendable {
    public var quotes: [CommentQuote]
    public var selectedThreadID: Int64?
    /// Whether every quoted passage shows, or only the selected thread's.
    public var showsAll: Bool

    public init(quotes: [CommentQuote] = [], selectedThreadID: Int64? = nil, showsAll: Bool = true) {
        self.quotes = quotes
        self.selectedThreadID = selectedThreadID
        self.showsAll = showsAll
    }
}
