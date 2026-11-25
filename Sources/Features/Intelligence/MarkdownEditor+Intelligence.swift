import Foundation
import Editor
import Markdown

extension FileSnapshot {
    package init(parsing source: String, sessionID: UUID, generation: UInt64) {
        let document = MarkdownDocument(source)
        let text = source as NSString
        let headings = document.blocks.filter { $0.kind == .heading }
            .map { text.lineRange(for: $0.range) }
        self.init(
            sessionID: sessionID, generation: generation, source: source,
            headingOffsets: headings.map(\.location),
            tasks: ModelTask.indexed(
                in: source, markers: document.tasks.compactMap(\.box), headings: headings))
    }
}

#if canImport(UIKit)
    import UIKit

    extension MarkdownEditor {
        func snapshot() -> FileSnapshot {
            FileSnapshot(parsing: document.text, sessionID: id, generation: generation)
        }

        func apply(_ proposal: Proposal, changeID: UUID? = nil) throws -> Proposal {
            let application = try proposal.application(to: snapshot(), changeID: changeID)
            try apply(
                document.edit(
                    replacing: document.range, with: application.source,
                    selection: application.mappedSelection(selection)))
            return application.remaining(on: self.snapshot())
        }
    }
#endif
