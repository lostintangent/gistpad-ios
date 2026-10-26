import Foundation
import GistPadIntelligence

extension NoteSnapshot {
  init(parsing source: String, documentID: String, sessionID: UUID, generation: UInt64) {
    let spans = MarkdownSyntax.spans(in: source)
    let protected = spans.filter { $0.kind == .code || $0.kind == .frontmatter }
    let markers = spans.filter { span in
      (span.kind == .task || span.kind == .checkedTask)
        && !protected.contains { NSIntersectionRange($0.range, span.range).length > 0 }
    }.map(\.range)
    let headings = spans.filter { $0.kind == .heading }.map(\.range)
    self.init(
      documentID: documentID, sessionID: sessionID, generation: generation, source: source,
      headingOffsets: headings.map(\.location),
      tasks: NoteTask.indexed(in: source, markers: markers, headings: headings))
  }
}

#if canImport(UIKit)
  import UIKit

  extension DocumentSession {
    public func intelligenceSnapshot() throws -> NoteSnapshot {
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
    public func applyIntelligenceProposal(
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
      let edit = SourceEdit(
        mutation: SourceMutation(
          range: NSRange(location: 0, length: snapshot.source.utf16.count),
          expected: snapshot.source, replacement: application.source),
        selection: try application.mappedSelection(textView.selectedRange))
      try apply(edit, generation: snapshot.generation)
      return try application.remainingReview(on: intelligenceSnapshot())
    }
  }
#endif
