import Foundation

public enum NotebookRouteError: Error, Equatable, Sendable {
    case unsupportedURL
    case invalidRoute
}

public enum NotebookRoute: Equatable, Sendable {
    case library
    case today
    case newNote
    case note(gistID: String, filename: String?, shared: Bool)
    case draft(accountID: UUID, draftID: UUID)

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil else {
            throw NotebookRouteError.unsupportedURL
        }
        let path: String
        switch components.scheme?.lowercased() {
        case "https":
            guard components.host?.lowercased() == "gistpad.dev" else {
                throw NotebookRouteError.unsupportedURL
            }
            if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
                guard components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
                      fragment.hasPrefix("/") else {
                    throw NotebookRouteError.invalidRoute
                }
                path = String(fragment.prefix { $0 != "?" })
            } else {
                path = components.percentEncodedPath
            }
        case "gistpad":
            guard let host = components.host,
                  ["library", "today", "new", "note", "share", "draft"].contains(host),
                  components.fragment == nil else {
                throw NotebookRouteError.unsupportedURL
            }
            path = "/" + host + components.percentEncodedPath
        default:
            throw NotebookRouteError.unsupportedURL
        }

        let encoded = path.split(separator: "/", omittingEmptySubsequences: false)
        guard encoded.first == "" else { throw NotebookRouteError.invalidRoute }
        var segments = try encoded.dropFirst().map { segment -> String in
            guard let decoded = String(segment).removingPercentEncoding,
                  !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw NotebookRouteError.invalidRoute }
            return decoded
        }
        if segments.last == "" { segments.removeLast() }
        guard !segments.contains("") else { throw NotebookRouteError.invalidRoute }

        if segments.isEmpty || segments == ["library"] {
            self = .library
        } else if segments == ["today"] {
            self = .today
        } else if segments == ["new"] {
            self = .newNote
        } else if segments.first == "draft", components.scheme?.lowercased() == "gistpad" {
            guard segments.count == 3, let account = UUID(uuidString: segments[1]),
                  let draft = UUID(uuidString: segments[2]) else {
                throw NotebookRouteError.invalidRoute
            }
            self = .draft(accountID: account, draftID: draft)
        } else {
            let explicitNote = segments.first == "note"
                && components.scheme?.lowercased() == "gistpad"
            let shared = segments.first == "share"
            if explicitNote || shared { segments.removeFirst() }
            guard (1...2).contains(segments.count), Self.validGistID(segments[0]),
                  segments.count < 2 || !segments[1].isEmpty else {
                throw NotebookRouteError.invalidRoute
            }
            self = .note(
                gistID: segments[0], filename: segments.count == 2 ? segments[1] : nil,
                shared: shared)
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "gistpad"
        switch self {
        case .library:
            components.host = "library"
        case .today:
            components.host = "today"
        case .newNote:
            components.host = "new"
        case .note(let gistID, let filename, let shared):
            components.host = shared ? "share" : "note"
            components.percentEncodedPath = "/" + Self.encode(gistID)
                + (filename.map { "/" + Self.encode($0) } ?? "")
        case .draft(let accountID, let draftID):
            components.host = "draft"
            components.path = "/\(accountID.uuidString)/\(draftID.uuidString)"
        }
        // All components are generated here, never copied from an unvalidated URL.
        return components.url!
    }

    private static func validGistID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    private static func encode(_ value: String) -> String {
        value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte)
                || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}
