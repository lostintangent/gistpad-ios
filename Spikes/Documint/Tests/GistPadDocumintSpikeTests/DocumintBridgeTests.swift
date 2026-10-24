import Foundation
import GistPadEditor
import Testing
@testable import GistPadDocumintSpike

struct DocumintBridgeTests {
    @Test("Bridge mutations preserve exact bytes and composed-character boundaries", arguments: [
        ("A thought", "A bright thought"),
        ("👩🏽‍💻 café e\u{301}", "👩🏽‍💻 café e\u{301}!"),
        ("Café", "Cafe\u{301}"),
        ("---\ntitle: \"Note\"\n---\n\nBody", "---\ntitle: \"Note\"\n---\n\nA body"),
        ("", "Hello"), ("A thought", "")
    ])
    func mutations(pair: (String, String)) throws {
        let mutation = try #require(DocumintBridge.mutation(from: pair.0, to: pair.1))
        #expect(try mutation.applying(to: pair.0).utf8.elementsEqual(pair.1.utf8))
    }

    @Test("Byte-identical snapshots never create source edits")
    func identicalSnapshot() {
        #expect(DocumintBridge.mutation(from: "A thought", to: "A thought") == nil)
    }

    @Test("Malformed and oversized bridge envelopes are rejected")
    func invalidMessages() throws {
        #expect(throws: (any Error).self) { try DocumintBridge.decode(["version": 2, "type": "ready"]) }
        #expect(throws: (any Error).self) {
            try DocumintBridge.decode(["version": 1, "type": "changed", "documentID": "note",
                "generation": "1", "revision": 1, "markdown": String(repeating: "x", count: DocumintBridge.maximumLength + 1)])
        }
        let ready = try DocumintBridge.decode(["version": 1, "type": "ready"])
        #expect(ready.type == "ready")
    }

    #if os(iOS)
    @MainActor
    @Test("Rich edits use the retained native source, draft callback and native Undo")
    func sourceTransaction() throws {
        let session = DocumentSession(documentID: "spike", text: "A quiet thought")
        var callbacks: [(String, UInt64)] = []
        session.onSourceChange = { callbacks.append(($0, $1)) }
        let identity = session.textView
        let mutation = try #require(DocumintBridge.mutation(from: session.text, to: "A useful quiet thought"))
        try session.apply(mutation, documentID: session.documentID, generation: session.generation)
        #expect(session.text == "A useful quiet thought")
        #expect(session.textView === identity)
        #expect(callbacks.count == 1 && callbacks[0].1 == 1)
        session.textView.undoManager?.undo()
        #expect(session.text == "A quiet thought")
        #expect(callbacks.count == 2)
        #expect(throws: SourceMutation.MutationError.staleGeneration) {
            try session.apply(mutation, documentID: session.documentID, generation: 0)
        }
    }
    #endif
}
