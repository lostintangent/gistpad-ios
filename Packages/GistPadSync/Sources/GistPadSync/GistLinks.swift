import Foundation

public struct GistLinks: Equatable, Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidGistID
        case invalidFilename
        case notPublished
    }

    public let shareURL: URL
    public let githubURL: URL
    public let isSecret: Bool

    public init(gist: Gist, filename: String? = nil) throws {
        guard !gist.id.isEmpty,
              gist.id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) }) else { throw Error.invalidGistID }
        if let filename {
            guard !filename.isEmpty, gist.files[filename] != nil else { throw Error.invalidFilename }
        }
        let suffix = filename.map { "/" + Self.encode($0) } ?? ""
        shareURL = URL(string: "https://gistpad.dev/#/share/\(gist.id)\(suffix)")!
        githubURL = URL(string: "https://gist.github.com/\(gist.id)")!
        isSecret = !gist.isPublic
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

extension GistLinks.Error: LocalizedError {
    public var errorDescription: String? {
        String(localized: "Publish this gist to get a link.")
    }
}
