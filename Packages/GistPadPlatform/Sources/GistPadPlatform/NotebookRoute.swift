import Foundation

public enum NotebookRoute: Codable, Hashable, Sendable {
    case today
    case addToToday
    case note(gistID: String, filename: String?)
    case draft(accountID: UUID, draftID: UUID)

    public init?(url: URL) {
        guard url.scheme == "gistpad" else { return nil }
        let path = Array(url.pathComponents.dropFirst())
        switch (url.host(), path.count) {
        case ("today", 0):
            self = .today
        case ("add-to-today", 0):
            self = .addToToday
        case ("note", 1), ("note", 2):
            self = .note(gistID: path[0], filename: path.count == 2 ? path[1] : nil)
        case ("draft", 2):
            guard let accountID = UUID(uuidString: path[0]),
                  let draftID = UUID(uuidString: path[1]) else { return nil }
            self = .draft(accountID: accountID, draftID: draftID)
        default:
            return nil
        }
    }

    public var url: URL {
        let (host, path): (String, [String]) = switch self {
        case .today: ("today", [])
        case .addToToday: ("add-to-today", [])
        case .note(let gistID, let filename): ("note", [gistID] + (filename.map { [$0] } ?? []))
        case .draft(let accountID, let draftID): ("draft", [accountID.uuidString, draftID.uuidString])
        }
        var url = URL(string: "gistpad://\(host)")!
        for component in path { url.append(path: component) }
        return url
    }
}
