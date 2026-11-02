import Foundation

public struct LibraryTaskProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public var remaining: Int { total - completed }

    public init(completed: Int, total: Int) {
        precondition(completed >= 0 && total >= completed)
        self.completed = completed
        self.total = total
    }
}

public enum LibraryTodayAvailability: Equatable, Sendable {
    case existing, missing, unknown
}

public struct LibraryTodaySummary: Equatable, Sendable {
    public var progress: LibraryTaskProgress?
    public var availability: LibraryTodayAvailability

    public var unfinishedTaskCount: Int? {
        availability == .existing ? progress?.remaining : nil
    }

    public init(
        progress: LibraryTaskProgress? = nil, availability: LibraryTodayAvailability = .unknown
    ) {
        self.progress = progress
        self.availability = availability
    }
}

public enum LibrarySearchState: Equatable, Sendable {
    case inactive
    case searching
    case results(notes: [LibraryNote])
    case failed(message: String)
}
