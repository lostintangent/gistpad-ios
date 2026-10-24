import Foundation

public enum PreviewFixtures {
    public static var allSyntax: String {
        get throws {
            guard let url = Bundle.module.url(forResource: "all-syntax", withExtension: "md", subdirectory: "Fixtures") else {
                throw PreviewFailure.renderer("The bundled Markdown fixture is missing.")
            }
            return try String(contentsOf: url, encoding: .utf8)
        }
    }
}
