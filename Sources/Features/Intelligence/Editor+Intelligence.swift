import Foundation
import Editor

extension FileSnapshot {
  package init(parsing source: String, fileID: String, sessionID: UUID, generation: UInt64) {
    let outline = Syntax.outline(in: source)
    let text = source as NSString
    let headings = outline.blocks.filter { $0.kind == .heading }
      .map { text.lineRange(for: $0.range) }
    self.init(
      fileID: fileID, sessionID: sessionID, generation: generation, source: source,
      headingOffsets: headings.map(\.location),
      tasks: ModelTask.indexed(
        in: source, markers: outline.taskMarkers, headings: headings))
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
