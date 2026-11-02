import Foundation
import Testing
@testable import GistPadInterface
@testable import GistPad
@testable import GistPadSync

@MainActor
struct LibraryGistCountTests {
    @Test func productionLibraryProjectionSuppliesPublishedGistIdentity() {
        let account = Account(
            id: UUID(), login: "synthetic-reader", preferences: .init(metadata: [:]))
        let owned = gist("owned")
        let daily = gist("daily", description: GistConventions.dailyNotesDescription)
        let shared = gist("shared")
        let snapshot = NotebookModel.librarySnapshot(
            owned: [owned, daily], starred: [owned, shared], account: account)
        #expect(Set(snapshot.notes.compactMap(\.gistID)) == ["owned", "daily", "shared"])
        let model = LibraryModel(snapshot: snapshot, loadState: .ready)
        #expect(model.mainGistCount == 1)
        #expect(model.count(in: .starred) == 1)
    }

    private func gist(_ id: String, description: String? = nil) -> Gist {
        let filenames = description == GistConventions.dailyNotesDescription
            ? ["2026-10-23.md", "2026-10-24.md"] : ["README.md", "Ideas.md"]
        let files = filenames.map { filename in
            (filename, GistFile(
                filename: filename, language: "Markdown", content: nil, truncated: false,
                rawURL: nil, size: nil))
        }
        return .init(
            id: id, description: description, files: Dictionary(uniqueKeysWithValues: files),
            updatedAt: InterfaceFixtures.referenceDate, createdAt: InterfaceFixtures.referenceDate,
            isPublic: false, owner: nil, truncated: false, history: nil, commentCount: nil)
    }
}
