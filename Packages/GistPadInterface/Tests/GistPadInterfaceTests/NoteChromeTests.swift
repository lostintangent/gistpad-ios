import Testing
@testable import GistPadInterface

struct NoteChromeTests {
    @Test(arguments: ["README.md", "readme.md", "ReadMe.MD"])
    func readmeFilenamesDoNotRepeatInTheHeader(filename: String) {
        let chrome = NoteChrome(
            title: "A notebook",
            files: [.init(id: "file", filename: filename), .init(id: "other", filename: "Other.md")],
            selectedFileID: "file")
        #expect(chrome.headerFilename == nil)
        #expect(chrome.files.first?.filename == filename)
    }

    @Test(arguments: ["Ideas.md", "2026-10-24.md", "README.txt", "readme.md.backup"])
    func otherSelectedFilenamesRemainExact(filename: String) {
        let chrome = NoteChrome(
            title: "A notebook",
            files: [.init(id: "file", filename: filename), .init(id: "other", filename: "Other.md")],
            selectedFileID: "file")
        #expect(chrome.headerFilename == filename)
    }

    @Test
    func singleFileNotesKeepOneTitleLine() {
        let chrome = NoteChrome(
            title: "A notebook", files: [.init(id: "file", filename: "Ideas.md")], selectedFileID: "file")
        #expect(chrome.headerFilename == nil)
    }

    @Test
    func missingSelectionDoesNotInventAHeaderFilename() {
        let chrome = NoteChrome(
            title: "A notebook", files: [.init(id: "file", filename: "Ideas.md")], selectedFileID: "missing")
        #expect(chrome.headerFilename == nil)
    }
}
