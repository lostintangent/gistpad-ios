import Foundation

public enum InterfaceFixtures {
    public static let referenceDate = Date(timeIntervalSince1970: 1_792_800_000)

    public static let library = LibrarySnapshot(
        notes: [
            LibraryNote(
                id: "shape", title: "The shape of a notebook", updatedAt: referenceDate, gistID: "shape",
                isPinned: true, tagIDs: ["ideas", "design"]
            ),
            LibraryNote(
                id: "weekend", title: "A slower weekend", updatedAt: referenceDate.addingTimeInterval(-3_600), gistID: "weekend",
                tagIDs: ["personal"]
            ),
            LibraryNote(
                id: "words", title: "Words worth keeping", updatedAt: referenceDate.addingTimeInterval(-86_400), gistID: "words",
                tagIDs: ["ideas"]
            ),
            LibraryNote(
                id: "mixed", title: "日本語のメモ · أفكار صغيرة", updatedAt: referenceDate.addingTimeInterval(-172_800), gistID: "mixed",
                tagIDs: ["personal"]
            ),
            LibraryNote(
                id: "daily", title: "Daily notes", updatedAt: referenceDate, gistID: "daily", isDailyNote: true
            ),
            LibraryNote(
                id: "starred", title: "An excellent Markdown field guide", updatedAt: referenceDate, gistID: "starred",
                owner: "notebook-friend", isOwned: false, isSecret: false, isStarred: true
            ),
            LibraryNote(
                id: "archived", title: "A finished chapter", updatedAt: referenceDate.addingTimeInterval(-604_800), gistID: "archived",
                isArchived: true
            )
        ],
        tags: [
            .init(id: "ideas", name: "Ideas", colorHex: "#EBC85A"),
            .init(id: "design", name: "Design", colorHex: "#548C80"),
            .init(id: "personal", name: "Personal", colorHex: "#A88EB5")
        ]
    )

    public static let note = NoteChrome(
        title: "The shape of a notebook",
        files: [.init(id: "README.md", filename: "README.md"), .init(id: "Ideas.md", filename: "Ideas.md")],
        selectedFileID: "README.md", isPinned: true, tags: library.tags.filter { ["ideas", "design"].contains($0.id) }
    )
}

#if os(iOS)
import SwiftUI

#Preview("Library") {
    @Previewable @State var model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
    NavigationSplitView {
        LibraryView(
            model: model, actions: .init(refresh: {}, create: {}, today: {}), isSidebar: true,
            expandedCollections: .constant(Set(LibraryCollection.allCases)), isPinnedExpanded: .constant(true)
        )
    } detail: {
        ContentUnavailableView("Select a gist", systemImage: "doc.text")
    }
    .librarySearch(model: model)
}

#Preview("Note chrome") {
    NavigationStack {
        NoteScreen(
            document: InterfaceFixtures.note, mode: .constant(.reading), saveState: .savedToGitHub
        ) {
            TextEditor(text: .constant("# The shape of a notebook\n\nA quiet place to think."))
        } preview: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("The shape of a notebook").font(.title.bold())
                    Text("A quiet place to think. A precise engine beneath the page.")
                    Text("These are synthetic screen fixtures. Nothing is connected to GitHub.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
    }
}
#endif
