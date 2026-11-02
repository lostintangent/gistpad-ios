import Foundation

/// The model's revised note, compared line by line with the part of the note it read. Each run of
/// changed lines becomes one candidate, so the review shows exactly what the model changed.
enum Revision {
  static func candidates(
    in source: String, visible: NSRange, revised: String
  ) throws -> [(ModelReplacement, NSRange)] {
    let newline = source.contains("\r\n") ? "\r\n" : "\n"
    let old = lines(in: source, visible: visible)
    var new = unwrapped(revised, note: old.map(\.text)).components(separatedBy: "\n")
    while new.first?.allSatisfy(\.isWhitespace) == true { new.removeFirst() }
    while new.last?.allSatisfy(\.isWhitespace) == true { new.removeLast() }
    if !hasLooseList(old.map(\.text)) { new = tightened(new) }
    // An unclosed fence would turn the rest of the note into code.
    guard !new.isEmpty, fences(in: new) % 2 == fences(in: old.map(\.text)) % 2 else {
      throw IntelligenceError.unsafeEdit
    }
    guard !old.isEmpty else {
      let text = source as NSString
      let needsBreak =
        visible.location > 0
        && !CharacterSet.newlines.contains(
          Unicode.Scalar(text.character(at: visible.location - 1)) ?? " ")
      return [
        (
          ModelReplacement(
            inserting: (needsBreak ? newline : "") + new.joined(separator: newline) + newline,
            reason: Kind.insert.reason),
          NSRange(location: visible.location, length: 0)
        )
      ]
    }
    let difference = new.map(key).difference(from: old.map { key($0.text) })
    var removed = Set<Int>()
    var inserted = Set<Int>()
    for change in difference {
      switch change {
      case .remove(let offset, _, _): removed.insert(offset)
      case .insert(let offset, _, _): inserted.insert(offset)
      }
    }
    // A line the model copied keeps its original text, including what the key ignores.
    var i = 0
    var j = 0
    while i < old.count, j < new.count {
      if removed.contains(i) {
        i += 1
      } else if inserted.contains(j) {
        j += 1
      } else {
        new[j] = old[i].text
        i += 1
        j += 1
      }
    }
    // Runs of changed lines, as old lines a..<b becoming new lines c..<d.
    var runs: [(a: Int, b: Int, c: Int, d: Int, kind: Kind)] = []
    i = 0
    j = 0
    while i < old.count || j < new.count {
      if i < old.count, j < new.count, !removed.contains(i), !inserted.contains(j) {
        i += 1
        j += 1
        continue
      }
      let a = i
      let c = j
      var advanced = true
      while advanced {
        advanced = false
        while i < old.count, removed.contains(i) {
          i += 1
          advanced = true
        }
        while j < new.count, inserted.contains(j) {
          j += 1
          advanced = true
        }
      }
      var run = (a: a, b: i, c: c, d: j, kind: a == i ? Kind.insert : c == j ? .remove : .change)
      // A quote needs existing text and a replacement needs a line to keep its line breaks, so a
      // run takes in unchanged lines before it, or after it at the top, until it quotes text.
      while run.a == run.b || run.c == run.d
        || old[run.a..<run.b].allSatisfy({ $0.text.allSatisfy(\.isWhitespace) })
      {
        if let last = runs.last, run.a == last.b {
          run = (last.a, run.b, last.c, run.d, last.kind == run.kind ? run.kind : .change)
          runs.removeLast()
        } else if run.a > 0 {
          run.a -= 1
          run.c -= 1
        } else if run.b < old.count {
          run.b += 1
          run.d += 1
        } else {
          break
        }
      }
      i = run.b
      j = run.d
      if let last = runs.last, run.a <= last.b {
        runs[runs.count - 1] = (
          last.a, max(last.b, run.b), last.c, max(last.d, run.d),
          last.kind == run.kind ? run.kind : .change
        )
      } else {
        runs.append(run)
      }
    }
    return runs.map { run in
      let range = NSRange(
        location: old[run.a].range.location,
        length: NSMaxRange(old[run.b - 1].range) - old[run.a].range.location)
      return (
        ModelReplacement(
          quote: (source as NSString).substring(with: range),
          replacement: new[run.c..<run.d].joined(separator: newline), reason: run.kind.reason),
        range
      )
    }
  }

  private enum Kind {
    case insert, remove, change

    var reason: String {
      switch self {
      case .insert: String(localized: "Add this text.", bundle: .module)
      case .remove: String(localized: "Remove this text.", bundle: .module)
      case .change: String(localized: "Change this text.", bundle: .module)
      }
    }
  }

  /// The model drops trailing spaces, respaces words and curls straight quotes, so a line that
  /// differs only there is unchanged.
  private static func key(_ line: String) -> String {
    let indent = line.prefix { $0 == " " || $0 == "\t" }
    let words = line.dropFirst(indent.count).split(whereSeparator: { $0 == " " || $0 == "\t" })
    return (indent + words.joined(separator: " "))
      .replacingOccurrences(of: "\u{2018}", with: "'")
      .replacingOccurrences(of: "\u{2019}", with: "'")
      .replacingOccurrences(of: "\u{201C}", with: "\"")
      .replacingOccurrences(of: "\u{201D}", with: "\"")
  }

  private static func isListItem(_ line: String) -> Bool {
    line.contains(#/^\s*(?:[-*+]|\d+[.)])\s/#)
  }

  /// Whether the note separates any two list items with a blank line.
  private static func hasLooseList(_ lines: [String]) -> Bool {
    lines.indices.contains { index in
      index > 0 && lines[index].allSatisfy(\.isWhitespace) && isListItem(lines[index - 1])
        && lines[index...].first { !$0.allSatisfy(\.isWhitespace) }.map(isListItem) == true
    }
  }

  /// The lines without blank lines between list items, so a tight list stays tight.
  private static func tightened(_ lines: [String]) -> [String] {
    lines.indices.compactMap { index in
      let line = lines[index]
      guard line.allSatisfy(\.isWhitespace),
        lines[..<index].last(where: { !$0.allSatisfy(\.isWhitespace) }).map(isListItem) == true,
        lines[index...].first(where: { !$0.allSatisfy(\.isWhitespace) }).map(isListItem) == true
      else { return line }
      return nil
    }
  }

  private static func fences(in lines: [String]) -> Int {
    lines.count { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
  }

  /// The visible lines without their line breaks, leaving out trailing blank lines.
  private static func lines(in source: String, visible: NSRange) -> [(text: String, range: NSRange)]
  {
    let text = source as NSString
    var lines: [(text: String, range: NSRange)] = []
    var location = visible.location
    let end = NSMaxRange(visible)
    while location < end {
      var lineEnd = location
      while lineEnd < end, text.character(at: lineEnd) != 0x0A { lineEnd += 1 }
      var contentEnd = lineEnd
      if contentEnd > location, text.character(at: contentEnd - 1) == 0x0D { contentEnd -= 1 }
      let range = NSRange(location: location, length: contentEnd - location)
      lines.append((text.substring(with: range), range))
      location = lineEnd + 1
    }
    while lines.last?.text.allSatisfy(\.isWhitespace) == true { lines.removeLast() }
    return lines
  }

  /// The model sometimes echoes a note of several lines as the JSON string it read, on one line
  /// with escaped line breaks, or fences its whole reply when the note doesn't start with a fence.
  private static func unwrapped(_ text: String, note: [String]) -> String {
    var text = text.replacingOccurrences(of: "\r\n", with: "\n")
    if note.count > 1, !text.contains("\n"), text.contains(#"\n"#) {
      var body = Substring(text.trimmingCharacters(in: .whitespaces))
      if body.hasPrefix(#"{"note":""#) { body = body.dropFirst(9) }
      if body.hasSuffix(#""}"#) { body = body.dropLast(2) }
      if let decoded = try? JSONDecoder().decode(String.self, from: Data(#""\#(body)""#.utf8)) {
        text = decoded
      }
    }
    if note.first?.hasPrefix("```") != true,
      let fenced = text.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(
        of: #/```(?:markdown|md)?[ \t]*\n([\s\S]*?)\n?```/#)
    {
      return String(fenced.1)
    }
    return text
  }
}
