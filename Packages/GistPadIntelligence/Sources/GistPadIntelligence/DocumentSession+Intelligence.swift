import Foundation
import GistPadEditor

extension NoteSnapshot {
  public init(parsing source: String, documentID: String, sessionID: UUID, generation: UInt64) {
    let outline = Syntax.outline(in: source)
    self.init(
      documentID: documentID, sessionID: sessionID, generation: generation, source: source,
      headingOffsets: outline.headings.map(\.location),
      tasks: NoteTask.indexed(
        in: source, markers: outline.taskMarkers, headings: outline.headings))
  }
}

#if canImport(UIKit)
  import UIKit

  extension Editor {
    func intelligenceSnapshot() throws -> NoteSnapshot {
      guard isSettled else {
        throw NoteIntelligenceError.unavailable(
          String(
            localized:
              "Finish composition or Writing Tools before starting an intelligence action.",
            bundle: .module))
      }
      return NoteSnapshot(
        parsing: text, documentID: fileID, sessionID: id, generation: generation)
    }

    @discardableResult
    func applyIntelligenceProposal(
      _ proposal: NoteProposal, commentID: UUID? = nil
    ) throws -> NoteProposal {
      guard textView.isEditable else {
        throw NoteIntelligenceError.unavailable(
          String(
            localized: "This gist is read-only, so changes can't be applied.",
            bundle: .module))
      }
      let snapshot = try intelligenceSnapshot()
      let application = try proposal.application(to: snapshot, commentID: commentID)
      let edit = Edit(
        range: NSRange(location: 0, length: snapshot.source.utf16.count),
        expected: snapshot.source, replacement: application.source,
        selection: try application.mappedSelection(textView.selectedRange))
      try apply(edit, generation: snapshot.generation)
      return try application.remainingReview(on: intelligenceSnapshot())
    }
  }
#endif
