import Foundation

@testable import Intelligence

func note(_ source: String) -> FileSnapshot {
  FileSnapshot(parsing: source, fileID: "note.md", sessionID: UUID(), generation: 0)
}

func request(
  _ source: String, _ action: IntelligenceAction, _ instruction: String = ""
) -> IntelligenceRequest {
  IntelligenceRequest(snapshot: note(source), action: action, instruction: instruction)
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
    FileSnapshot(
      fileID: fileID, sessionID: sessionID, generation: generation + 1, source: source)
  }
}
