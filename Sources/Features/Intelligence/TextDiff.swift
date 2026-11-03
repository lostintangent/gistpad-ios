import Foundation
import NaturalLanguage
import SwiftUI

struct TextDiff: Sendable {
  enum Kind: Sendable { case unchanged, removed, added }

  struct Run: Sendable {
    let kind: Kind
    let text: String
  }

  let before: [Run]
  let after: [Run]

  init(before: String, after: String) {
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
    _ tokens: [String], changed: Set<Int>, kind: Kind
  ) -> [Run] {
    var result: [Run] = []
    var text = ""
    var current = Kind.unchanged
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

enum DiffText {
  static func attributed(_ runs: [TextDiff.Run]) -> AttributedString {
    var result = AttributedString()
    for run in runs {
      var text = AttributedString(run.text)
      switch run.kind {
      case .unchanged:
        text.foregroundColor = .primary
      case .removed:
        text.foregroundColor = .secondary
        text.strikethroughStyle = Text.LineStyle(pattern: .solid)
      case .added:
        text.foregroundColor = .primary
        text.font = .body.weight(.semibold)
        text.underlineStyle = Text.LineStyle(pattern: .solid)
      }
      result += text
    }
    return result
  }
}
