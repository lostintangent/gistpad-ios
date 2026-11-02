import Foundation

public enum SampleLibrary {
    public static let referenceDate = Date(timeIntervalSince1970: 1_792_800_000)

    public static let gists: [GistItem] = [
        GistItem(
            id: "shape", title: "The shape of a gist", updatedAt: referenceDate, gistID: "shape",
            isPinned: true, tagIDs: ["ideas", "design"], fileCount: 2
        ),
        GistItem(
            id: "weekend", title: "A slower weekend", updatedAt: referenceDate.addingTimeInterval(-3_600), gistID: "weekend",
            tagIDs: ["personal"]
        ),
        GistItem(
            id: "words", title: "Words worth keeping", updatedAt: referenceDate.addingTimeInterval(-86_400), gistID: "words",
            tagIDs: ["ideas"]
        ),
        GistItem(
            id: "mixed", title: "日本語のメモ · أفكار صغيرة", updatedAt: referenceDate.addingTimeInterval(-172_800), gistID: "mixed",
            tagIDs: ["personal"]
        ),
        GistItem(
            id: "daily", title: "Daily notes", updatedAt: referenceDate, gistID: "daily", isDailyNote: true
        ),
        GistItem(
            id: "starred", title: "An excellent Markdown field guide", updatedAt: referenceDate, gistID: "starred",
            owner: "notebook-friend", isOwned: false, isSecret: false, isStarred: true
        ),
        GistItem(
            id: "archived", title: "A finished chapter", updatedAt: referenceDate.addingTimeInterval(-604_800), gistID: "archived",
            isArchived: true
        )
    ]

    public static let tags: [Tag] = [
        .init(id: "ideas", name: "Ideas", colorHex: "#EBC85A"),
        .init(id: "design", name: "Design", colorHex: "#548C80"),
        .init(id: "personal", name: "Personal", colorHex: "#A88EB5")
    ]

    public static let gist = GistDetails(
        title: "The shape of a gist",
        files: [.init(id: "README.md", filename: "README.md"), .init(id: "Ideas.md", filename: "Ideas.md")],
        selectedFileID: "README.md", isPinned: true, tags: tags.filter { ["ideas", "design"].contains($0.id) },
        shareURL: URL(string: "https://gistpad.dev/#/share/fixture/README.md")
    )
}

#if os(iOS)
import SwiftUI

#Preview("Library") {
    @Previewable @State var state = LibraryState(
        gists: SampleLibrary.gists, tags: SampleLibrary.tags, loadState: .ready)
    NavigationSplitView {
        LibraryView(
            state: state, actions: .init(refresh: {}, create: {}, today: {}), isSidebar: true,
            expandedSections: .constant(Set(LibrarySection.allCases)), isPinnedExpanded: .constant(true)
        )
    } detail: {
        ContentUnavailableView("Select a gist", systemImage: "doc.text")
    }
    .librarySearch(state: state)
}

#Preview("Gist") {
    NavigationStack {
        GistScreen(
            gist: SampleLibrary.gist, mode: .constant(.preview), saveState: .savedToGitHub
        ) {
            TextEditor(text: .constant("# The shape of a gist\n\nA quiet place to think."))
        } preview: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("The shape of a gist").font(.title.bold())
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
