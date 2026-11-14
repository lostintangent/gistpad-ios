import Foundation

@testable import Intelligence

func note(_ source: String) -> FileSnapshot {
  FileSnapshot(parsing: source, sessionID: UUID(), generation: 0)
}

func request(_ source: String, _ instruction: String = "") -> IntelligenceRequest {
  IntelligenceRequest(snapshot: note(source), instruction: instruction)
}

/// The model revising everything it was shown.
func rewrite(_ revised: String) -> (ModelPass) -> [ModelEdit] {
  { [.rewriteRegion(NSRange(location: 0, length: $0.source.utf16.count), revised: revised)] }
}

func change(_ quote: String, _ replacement: String?) -> ModelReplacement {
  ModelReplacement(quote: quote, replacement: replacement, reason: "Improve")
}

extension Review {
  init(snapshot: FileSnapshot, candidates: [ModelReplacement]) {
    self.init(
      snapshot: snapshot,
      scopedCandidates: candidates.map {
        ($0, NSRange(location: 0, length: snapshot.source.utf16.count))
      })
  }
}

extension FileSnapshot {
  func edited(to source: String) -> FileSnapshot {
    FileSnapshot(sessionID: sessionID, generation: generation + 1, source: source)
  }
}
