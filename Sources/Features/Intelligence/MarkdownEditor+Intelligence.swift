import Foundation
import Editor

extension FileSnapshot {
    package init(parsing source: String, sessionID: UUID, generation: UInt64) {
        let outline = Syntax.outline(in: source)
        let text = source as NSString
        let headings = outline.blocks.filter { $0.kind == .heading }
            .map { text.lineRange(for: $0.range) }
        self.init(
            sessionID: sessionID, generation: generation, source: source,
            headingOffsets: headings.map(\.location),
            tasks: ModelTask.indexed(
                in: source, markers: outline.taskMarkers, headings: headings))
    }
}

#if canImport(UIKit)
    import UIKit

    extension MarkdownEditor {
        func snapshot() -> FileSnapshot {
            FileSnapshot(parsing: text, sessionID: id, generation: generation)
        }

        func apply(_ proposal: Proposal, changeID: UUID? = nil) throws -> Proposal {
            let snapshot = snapshot()
            let application = try proposal.application(to: snapshot, changeID: changeID)
            let edit = Edit(
                range: NSRange(location: 0, length: snapshot.source.utf16.count),
                expected: snapshot.source, replacement: application.source,
                selection: application.mappedSelection(selection))
            try apply(edit, generation: snapshot.generation)
            return application.remaining(on: self.snapshot())
        }
    }
#endif
