import Foundation

public enum LibrarySearchState: Equatable, Sendable {
    case inactive
    case searching
    case results(notes: [LibraryNote])
    case failed(message: String)
}
