import Foundation

struct EditBlock {
  enum Kind: String {
    case heading, paragraph, listItem, tableRow, code
  }

  let id: Int
  let kind: Kind
  let range: NSRange
  let text: String
  let heading: String

  static func moveTarget(in instruction: String) -> String? {
    instruction.firstMatch(of: /(?i)\b(?:move|relocate)\s+(.+?)\s+from\s+.+?\s+to\s+/)
      .map { String($0.1) }
  }

  static func indexed(in source: String) -> [Self] {
    let text = source as NSString
    var blocks: [Self] = []
    var current: (start: Int, end: Int, kind: Kind, heading: String)?
    var heading = ""
    var fence: String?

    func finish() {
      guard let active = current else { return }
      let range = NSRange(location: active.start, length: active.end - active.start)
      blocks.append(
        Self(
          id: blocks.count + 1, kind: active.kind, range: range,
          text: text.substring(with: range), heading: active.heading))
      current = nil
    }

    func append(_ start: Int, _ end: Int, kind: Kind, continuing: Bool = false) {
      if continuing, let active = current, active.kind == kind {
        current?.end = end
      } else {
        finish()
        current = (start, end, kind, heading)
      }
    }

    var offset = 0
    while offset < text.length {
      let lineRange = text.lineRange(for: NSRange(location: offset, length: 0))
      var end = NSMaxRange(lineRange)
      while end > offset
        && (text.character(at: end - 1) == 0x0A
          || text.character(at: end - 1) == 0x0D)
      {
        end -= 1
      }
      let line = text.substring(with: NSRange(location: offset, length: end - offset))
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let delimiter = String(trimmed.prefix { $0 == "`" || $0 == "~" })
      if let activeFence = fence {
        append(offset, end, kind: .code, continuing: true)
        if trimmed.hasPrefix(activeFence),
          trimmed.dropFirst(activeFence.count).allSatisfy(\.isWhitespace)
        {
          finish()
          fence = nil
        }
      } else if delimiter.count >= 3 {
        append(offset, end, kind: .code)
        fence = delimiter
      } else if trimmed.isEmpty {
        finish()
      } else if line.range(of: #"^ {0,3}#{1,6}[ \t]"#, options: .regularExpression) != nil {
        heading = line
        append(offset, end, kind: .heading)
        finish()
      } else if line.range(
        of: #"^\s*(?:[-*+]|\d+[.)])[ \t]"#, options: .regularExpression) != nil
      {
        append(offset, end, kind: .listItem)
      } else if trimmed.hasPrefix("|") {
        append(offset, end, kind: .tableRow)
      } else if let active = current,
        active.kind == .paragraph
          || (active.kind == .listItem && line.first?.isWhitespace == true)
      {
        append(offset, end, kind: active.kind, continuing: true)
      } else {
        append(offset, end, kind: .paragraph)
      }
      offset = NSMaxRange(lineRange)
    }
    finish()
    return blocks
  }
}

struct EditSection {
  let id: Int
  let title: String
  let level: Int
  let range: NSRange
  let text: String
  let directRange: NSRange

  static func indexed(in source: String) -> [Self] {
    let headings = EditBlock.indexed(in: source).filter { $0.kind == .heading }
    let text = source as NSString
    return headings.enumerated().map { index, heading in
      let level = heading.text.trimmingCharacters(in: .whitespaces)
        .prefix { $0 == "#" }.count
      let next = headings.dropFirst(index + 1).first {
        $0.text.trimmingCharacters(in: .whitespaces).prefix { $0 == "#" }.count <= level
      }
      let nextHeading = headings.dropFirst(index + 1).first?.range.location ?? text.length
      var end = next?.range.location ?? text.length
      while end > NSMaxRange(heading.range)
        && (text.character(at: end - 1) == 0x0A || text.character(at: end - 1) == 0x0D)
      {
        end -= 1
      }
      var directEnd = nextHeading
      while directEnd > NSMaxRange(heading.range)
        && (text.character(at: directEnd - 1) == 0x0A
          || text.character(at: directEnd - 1) == 0x0D)
      {
        directEnd -= 1
      }
      let range = NSRange(location: heading.range.location, length: end - heading.range.location)
      return Self(
        id: index + 1, title: heading.text, level: level, range: range,
        text: text.substring(with: range),
        directRange: NSRange(
          location: heading.range.location, length: directEnd - heading.range.location))
    }
  }
}
