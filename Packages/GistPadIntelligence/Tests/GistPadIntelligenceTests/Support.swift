import Foundation

@testable import GistPadIntelligence

func note(_ source: String) -> NoteSnapshot {
  NoteSnapshot(parsing: source, documentID: "note.md", sessionID: UUID(), generation: 0)
}

func request(
  _ source: String, _ action: NoteIntelligenceAction, _ instruction: String = ""
) -> NoteIntelligenceRequest {
  NoteIntelligenceRequest(snapshot: note(source), action: action, instruction: instruction)
}

func change(_ quote: String, _ replacement: String?) -> NoteReplacementCandidate {
  NoteReplacementCandidate(quote: quote, replacement: replacement, reason: "Improve")
}

extension NoteSnapshot {
  func edited(to source: String) -> NoteSnapshot {
    NoteSnapshot(
      documentID: documentID, sessionID: sessionID, generation: generation + 1, source: source)
  }
}
