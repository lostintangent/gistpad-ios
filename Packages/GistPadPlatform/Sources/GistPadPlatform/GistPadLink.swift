import Foundation
import Observation

/// A `gistpad://` link from a widget, control, Shortcut or Spotlight. The hosts are
/// what Spotlight already indexed, so they keep their original names.
public enum GistPadLink: Codable, Hashable, Sendable {
    case today
    case addToToday
    case gist(id: String, filename: String?)
    case unpublishedGist(accountID: UUID, draftID: UUID)

    public init?(url: URL) {
        guard url.scheme == "gistpad" else { return nil }
        let path = Array(url.pathComponents.dropFirst())
        switch (url.host(), path.count) {
        case ("today", 0):
            self = .today
        case ("add-to-today", 0):
            self = .addToToday
        case ("note", 1), ("note", 2):
            self = .gist(id: path[0], filename: path.count == 2 ? path[1] : nil)
        case ("draft", 2):
            guard let accountID = UUID(uuidString: path[0]),
                  let draftID = UUID(uuidString: path[1]) else { return nil }
            self = .unpublishedGist(accountID: accountID, draftID: draftID)
        default:
            return nil
        }
    }

    public var url: URL {
        let (host, path): (String, [String]) = switch self {
        case .today: ("today", [])
        case .addToToday: ("add-to-today", [])
        case .gist(let id, let filename): ("note", [id] + (filename.map { [$0] } ?? []))
        case .unpublishedGist(let accountID, let draftID): ("draft", [accountID.uuidString, draftID.uuidString])
        }
        var url = URL(string: "gistpad://\(host)")!
        for component in path { url.append(path: component) }
        return url
    }
}

/// The link the app opens next, set by an intent or `onOpenURL`.
@MainActor @Observable
public final class PendingLink {
    public static let shared = PendingLink()
    public var link: GistPadLink?

    public init() {}
}
