import Foundation
import NaturalLanguage

public struct NoteTextDiff: Sendable {
  public struct Run: Sendable {
    public let kind: NoteDiffLine.Kind
    public let text: String
  }

  public let before: [Run]
  public let after: [Run]

  public init(before: String, after: String) {
    let old = Self.tokens(before)
    let new = Self.tokens(after)
    let difference = new.difference(from: old) { $0.utf8.elementsEqual($1.utf8) }
    var removals = Set<Int>()
    var insertions = Set<Int>()
    for change in difference {
      switch change {
      case .remove(let offset, _, _): removals.insert(offset)
      case .insert(let offset, _, _): insertions.insert(offset)
      }
    }
    self.before = Self.runs(old, changed: removals, kind: .removed)
    self.after = Self.runs(new, changed: insertions, kind: .added)
  }

  private static func tokens(_ source: String) -> [String] {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = source
    var result: [String] = []
    var cursor = source.startIndex
    tokenizer.enumerateTokens(in: source.startIndex..<source.endIndex) { range, _ in
      if cursor < range.lowerBound {
        result.append(contentsOf: source[cursor..<range.lowerBound].map { String($0) })
      }
      result.append(String(source[range]))
      cursor = range.upperBound
      return true
    }
    if cursor < source.endIndex {
      result.append(contentsOf: source[cursor...].map { String($0) })
    }
    return result
  }

  private static func runs(
    _ tokens: [String], changed: Set<Int>, kind: NoteDiffLine.Kind
  ) -> [Run] {
    var result: [Run] = []
    var text = ""
    var current = NoteDiffLine.Kind.unchanged
    for (offset, token) in tokens.enumerated() {
      let next = changed.contains(offset) ? kind : .unchanged
      if next != current, !text.isEmpty {
        result.append(Run(kind: current, text: text))
        text = ""
      }
      current = next
      text.append(contentsOf: token)
    }
    if !text.isEmpty { result.append(Run(kind: current, text: text)) }
    return result
  }
}
