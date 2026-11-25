import Foundation

/// The passages a note's comments quote, and what tapping, linking and adding one does. A surface
/// without annotations has no comments.
public struct CommentAnnotations: Sendable {
    public var quotes: [CommentQuote]
    public var selectedThreadID: Int64?
    /// Changes when the selected thread should scroll into view again.
    public var revealRevision: UInt64
    public var showsInlineComments: Bool
    /// Opens the threads under a tapped passage.
    public var open: @MainActor ([Int64]) -> Void
    /// Reports which threads still find their passage in the text.
    public var linked: @MainActor (Set<Int64>) -> Void
    /// Starts a thread that quotes the selected text.
    public var add: @MainActor (String) -> Void

    public init(
        quotes: [CommentQuote] = [], selectedThreadID: Int64? = nil, revealRevision: UInt64 = 0,
        showsInlineComments: Bool = true, open: @escaping @MainActor ([Int64]) -> Void,
        linked: @escaping @MainActor (Set<Int64>) -> Void, add: @escaping @MainActor (String) -> Void
    ) {
        self.quotes = quotes
        self.selectedThreadID = selectedThreadID
        self.revealRevision = revealRevision
        self.showsInlineComments = showsInlineComments
        self.open = open
        self.linked = linked
        self.add = add
    }
}

extension CommentAnnotations: Equatable {
    /// Two values are equal when they show the same annotations. Every view update makes new
    /// closures, so they never count.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.quotes == rhs.quotes && lhs.selectedThreadID == rhs.selectedThreadID
            && lhs.revealRevision == rhs.revealRevision && lhs.showsInlineComments == rhs.showsInlineComments
    }
}
