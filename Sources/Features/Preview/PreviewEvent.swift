import Foundation

public enum PreviewEvent: Equatable, Sendable {
    /// Flips one validated task marker in the text of `generation`.
    case taskToggle(range: NSRange, expected: String, replacement: String, generation: UInt64)
    case openURL(URL)
    case openWikilink(String)
    case failure(String)
}
