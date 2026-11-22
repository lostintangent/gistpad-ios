import Foundation

public enum PreviewFixtures {
    public static var allSyntax: String {
        get throws { try load("all-syntax") }
    }

    public static var readingPolish: String {
        get throws { try load("reading-polish") }
    }

    public static var listMarkers: String {
        get throws { try load("list-markers") }
    }

    private static func load(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Fixtures") else {
            throw PreviewError("The bundled Markdown fixture '\(name)' is missing.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
