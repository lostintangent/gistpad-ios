#if canImport(UIKit)
    import Editor
    import Foundation

    extension MarkdownEditor {
        /// Applies the proposal as one undoable edit made from the note it was proposed for, which the
        /// editor refuses once the note has changed.
        func apply(_ proposal: Proposal, changeID: UUID? = nil) throws -> Proposal {
            let application = try proposal.application(changeID: changeID)
            let note = proposal.document
            try apply(
                note.edit(
                    replacing: note.range, with: application.source,
                    selection: application.mappedSelection(selection)))
            return application.remaining(on: document)
        }
    }
#endif
