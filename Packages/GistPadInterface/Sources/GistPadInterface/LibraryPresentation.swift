import Foundation

public struct LibraryTaskProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int

    public init(completed: Int, total: Int) {
        precondition(completed >= 0 && total >= completed)
        self.completed = completed
        self.total = total
    }
}

public struct LibraryTodaySummary: Equatable, Sendable {
    public var date: Date
    public var timeZone: TimeZone
    public var progress: LibraryTaskProgress?

    public init(date: Date, timeZone: TimeZone = .current, progress: LibraryTaskProgress? = nil) {
        self.date = date
        self.timeZone = timeZone
        self.progress = progress
    }
}

public struct LibrarySearchCoverage: Equatable, Sendable {
    public let totalDocuments: Int
    public let documentsWithCachedContent: Int
    public let incompleteGistCount: Int
    public let staleResultCount: Int

    public init(
        totalDocuments: Int, documentsWithCachedContent: Int,
        incompleteGistCount: Int = 0, staleResultCount: Int = 0
    ) {
        precondition(
            totalDocuments >= 0 && documentsWithCachedContent >= 0
                && documentsWithCachedContent <= totalDocuments
                && incompleteGistCount >= 0 && staleResultCount >= 0
        )
        self.totalDocuments = totalDocuments
        self.documentsWithCachedContent = documentsWithCachedContent
        self.incompleteGistCount = incompleteGistCount
        self.staleResultCount = staleResultCount
    }

    public var isComplete: Bool {
        documentsWithCachedContent == totalDocuments && incompleteGistCount == 0 && staleResultCount == 0
    }
}

public enum LibrarySearchState: Equatable, Sendable {
    case inactive
    case searching
    case results(notes: [LibraryNote], coverage: LibrarySearchCoverage)
    case failed(message: String)
}
