import Foundation
import GistPadEditor

extension NoteSnapshot {
  public init(parsing source: String, documentID: String, sessionID: UUID, generation: UInt64) {
    let outline = MarkdownSyntax.outline(in: source)
    self.init(
      documentID: documentID, sessionID: sessionID, generation: generation, source: source,
      headingOffsets: outline.headings.map(\.location),
      tasks: NoteTask.indexed(
        in: source, markers: outline.taskMarkers, headings: outline.headings))
  }
}

#if canImport(UIKit)
  import UIKit

  extension DocumentSession {
    func intelligenceSnapshot() throws -> NoteSnapshot {
      guard !isComposing, !writingToolsActive, textView.markedTextRange == nil else {
        throw NoteIntelligenceError.unavailable(
          String(
            localized:
              "Finish composition or Writing Tools before starting an intelligence action.",
            bundle: .module))
      }
      return NoteSnapshot(
        parsing: text, documentID: documentID, sessionID: viewIdentity, generation: generation)
    }

    @discardableResult
    func applyIntelligenceProposal(
      _ proposal: NoteProposal, commentID: UUID? = nil
    ) throws -> NoteProposal {
      guard textView.isEditable else {
        throw NoteIntelligenceError.unavailable(
          String(
            localized: "This note is read-only. Suggested changes can't be applied.",
            bundle: .module))
      }
      let snapshot = try intelligenceSnapshot()
      let application = try proposal.application(to: snapshot, commentID: commentID)
      let selection = try application.mappedSelection(textView.selectedRange)
      try apply(
        SourceMutation(
          range: NSRange(location: 0, length: snapshot.source.utf16.count),
          expected: snapshot.source, replacement: application.source),
        documentID: documentID, generation: snapshot.generation)
      textView.selectedRange = selection
      textView.scrollRangeToVisible(selection)
      return try application.remainingReview(on: intelligenceSnapshot())
    }
  }
#endif
