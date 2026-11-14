import Foundation
import Editor

struct EditBlock {
  typealias Kind = Syntax.Block.Kind

  let id: Int
  let kind: Kind
  let range: NSRange
  let text: String
  let heading: String
  let level: Int
  let marker: NSRange?
  let taskMarker: NSRange?

  static func moveTarget(in instruction: String) -> String? {
    instruction.firstMatch(of: /(?i)\b(?:move|relocate)\s+(.+?)\s+from\s+.+?\s+to\s+/)
      .map { String($0.1) }
  }

  static func headingName(_ heading: String, level: Int) -> String {
    let content = heading.drop(while: { $0 == " " }).dropFirst(level)
    guard content.first?.isWhitespace == true else { return heading }
    return String(content.drop(while: \.isWhitespace))
  }

  static func indexed(in source: String) -> [Self] {
    let text = source as NSString
    var heading = ""
    return Syntax.outline(in: source).blocks.enumerated().map { index, block in
      let value = text.substring(with: block.range)
      if block.kind == .heading { heading = value }
      return Self(
        id: index + 1, kind: block.kind, range: block.range,
        text: value, heading: heading, level: block.level ?? 0,
        marker: block.marker, taskMarker: block.taskMarker)
    }
  }
}

struct EditSection {
  let id: Int
  let title: String
  let level: Int
  let range: NSRange
  let text: String
  let directRange: NSRange
  var name: String { EditBlock.headingName(title, level: level) }

  static func indexed(in source: String) -> [Self] {
    let headings = EditBlock.indexed(in: source).filter { $0.kind == .heading }
    let text = source as NSString
    return headings.enumerated().map { index, heading in
      let level = heading.level
      let next = headings.dropFirst(index + 1).first {
        $0.level <= level
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
