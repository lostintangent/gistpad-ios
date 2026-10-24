import Foundation

enum NoteEditSafety {
  static func validate(
    source: String, replacement: String, instruction: String,
    changes: [NoteProposalComment]
  ) throws {
    guard !source.isEmpty else { return }
    let request = normalized(instruction)
    for change in changes {
      if let replacement = change.replacement, !request.isEmpty,
        normalized(replacement) == request
      {
        throw NoteIntelligenceError.unsafeEdit
      }
    }
    guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw NoteIntelligenceError.unsafeEdit
    }
    let originalCount = source.filter { !$0.isWhitespace }.count
    let replacementCount = replacement.filter { !$0.isWhitespace }.count
    guard replacementCount <= min(12, originalCount / 4) else { return }
    let retained = NoteTextDiff(before: source, after: replacement).before
      .filter { $0.kind == .unchanged }.reduce(0) { $0 + $1.text.utf8.count }
    if retained * 10 < source.utf8.count {
      throw NoteIntelligenceError.unsafeEdit
    }
  }

  private static func normalized(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
      .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
  }
}
