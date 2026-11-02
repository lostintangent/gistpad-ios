import Foundation
import GistPadEditor

extension FileSnapshot {
  public init(parsing source: String, fileID: String, sessionID: UUID, generation: UInt64) {
    let outline = Syntax.outline(in: source)
    self.init(
      fileID: fileID, sessionID: sessionID, generation: generation, source: source,
      headingOffsets: outline.headings.map(\.location),
      tasks: ModelTask.indexed(
        in: source, markers: outline.taskMarkers, headings: outline.headings))
  }
}

#if canImport(UIKit)
  import UIKit

  extension Editor {
    func snapshot() throws -> FileSnapshot {
      guard isSettled else {
        throw IntelligenceError.unavailable(
          String(
            localized: "Finish typing or wait for Writing Tools, then try again.",
            bundle: .module))
      }
      return FileSnapshot(
        parsing: text, fileID: fileID, sessionID: id, generation: generation)
    }

    @discardableResult
    func apply(
      _ review: Review, commentID: UUID? = nil
    ) throws -> Review {
      guard textView.isEditable else {
        throw IntelligenceError.unavailable(
          String(
            localized: "This gist is read-only, so changes can't be applied.",
            bundle: .module))
      }
      let snapshot = try snapshot()
      let application = try review.application(to: snapshot, commentID: commentID)
      let edit = Edit(
        range: NSRange(location: 0, length: snapshot.source.utf16.count),
        expected: snapshot.source, replacement: application.source,
        selection: try application.mappedSelection(textView.selectedRange))
      try apply(edit, generation: snapshot.generation)
      return try application.remainingReview(on: self.snapshot())
    }
  }
#endif
