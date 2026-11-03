import Foundation

/// One change to a note's source, with UTF-16 offsets.
public struct Edit: Sendable {
  public let range: NSRange
  public let expected: String
  public let replacement: String
  /// The selection after the edit, or nil to keep the caret where it was.
  public let selection: NSRange?

  public init(range: NSRange, expected: String, replacement: String, selection: NSRange? = nil) {
    self.range = range
    self.expected = expected
    self.replacement = replacement
    self.selection = selection
  }

  /// Replacements are ordered, nonoverlapping UTF-16 ranges in the original source.
  init(
    range: NSRange, expected: String, replacements: [(range: NSRange, replacement: String)],
    selection: NSRange
  ) {
    var start = selection.location
    var end = NSMaxRange(selection)
    var delta = 0
    for replacement in replacements {
      let current = NSRange(
        location: replacement.range.location + delta, length: replacement.range.length)
      let length = replacement.replacement.utf16.count
      start = Self.remap(start, through: current, replacementLength: length)
      end = Self.remap(end, through: current, replacementLength: length)
      delta += length - replacement.range.length
    }
    let result = NSMutableString(string: expected)
    for replacement in replacements.reversed() {
      result.replaceCharacters(
        in: NSRange(
          location: replacement.range.location - range.location, length: replacement.range.length),
        with: replacement.replacement)
    }
    self.init(
      range: range, expected: expected, replacement: result as String,
      selection: NSRange(location: start, length: end - start))
  }

  public func applying(to source: String) throws -> String {
    guard try Self.text(in: source, at: range).utf8.elementsEqual(expected.utf8) else {
      throw MutationError.sourceChanged
    }
    return (source as NSString).replacingCharacters(in: range, with: replacement)
  }

  /// The source at `range`, which must be in bounds and must not split a surrogate pair.
  static func text(in source: String, at range: NSRange) throws -> String {
    let utf16 = source as NSString
    guard range.location >= 0, range.length >= 0, range.location <= utf16.length,
      range.length <= utf16.length - range.location
    else { throw MutationError.invalidRange }
    for boundary in [range.location, NSMaxRange(range)]
    where boundary > 0 && boundary < utf16.length {
      guard !(0xD800...0xDBFF).contains(utf16.character(at: boundary - 1))
        || !(0xDC00...0xDFFF).contains(utf16.character(at: boundary))
      else { throw MutationError.invalidRange }
    }
    return utf16.substring(with: range)
  }

  private static func remap(_ offset: Int, through range: NSRange, replacementLength: Int) -> Int {
    if offset < range.location { return offset }
    if offset >= NSMaxRange(range) { return offset + replacementLength - range.length }
    return range.location + min(offset - range.location, replacementLength)
  }

  public enum MutationError: Error, Equatable {
    case invalidRange
    case sourceChanged
    case staleGeneration
    case compositionActive
  }
}

extension Edit.MutationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .compositionActive:
      String(
        localized:
          "Finish composition or Writing Tools before continuing. Your current draft is unchanged.",
        bundle: .module)
    case .invalidRange, .sourceChanged, .staleGeneration:
      String(
        localized: "This file changed. Review the latest version first.",
        bundle: .module)
    }
  }
}

enum Format: Sendable {
  case heading(Int)
  case bold, italic, bulletList, numberedList, checklist, quote
  case inlineCode, codeBlock
  case link(label: String, destination: String)
}

enum Formatting {
  enum FormattingError: Error, Equatable {
    case invalidLink
  }

  static func edit(
    _ format: Format, in source: String, selection: NSRange
  ) throws -> Edit? {
    let text = source as NSString
    let selected = try Edit.text(in: source, at: selection)
    switch format {
    case .bold:
      return wrapped("**", source: source, selection: selection, selected: selected)
    case .italic:
      return wrapped("*", source: source, selection: selection, selected: selected)
    case .inlineCode:
      if let edit = unwrappedCode(in: source, selection: selection, selected: selected) {
        return edit
      }
      let delimiter = String(repeating: "`", count: longestBacktickRun(selected) + 1)
      let padded =
        selected.hasPrefix("`") || selected.hasSuffix("`")
        || (selected.hasPrefix(" ") && selected.hasSuffix(" ")
          && !selected.allSatisfy(\.isWhitespace))
      let padding = padded ? " " : ""
      let replacement = delimiter + padding + selected + padding + delimiter
      return Edit(
        range: selection, expected: selected, replacement: replacement,
        selection: NSRange(
          location: selection.location + delimiter.utf16.count + padding.utf16.count,
          length: selected.utf16.count))
    case .link(let label, let destination):
      let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let url = URL(string: destination), let scheme = url.scheme?.lowercased(),
        ["http", "https", "mailto", "tel"].contains(scheme),
        !destination.contains("\n"), !destination.contains("\r"),
        !destination.contains("<"), !destination.contains(">"),
        !label.contains("\n"), !label.contains("\r"),
        (scheme != "http" && scheme != "https") || !(url.host ?? "").isEmpty,
        (scheme != "mailto" && scheme != "tel") || !url.path.isEmpty
      else { throw FormattingError.invalidLink }
      let target = url.absoluteString
      let escaped = target.contains("(") || target.contains(")") ? "<\(target)>" : target
      let title = (label.isEmpty ? target : label)
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "[", with: "\\[")
        .replacingOccurrences(of: "]", with: "\\]")
      let replacement = "[\(title)](\(escaped))"
      return Edit(
        range: selection, expected: selected, replacement: replacement,
        selection: NSRange(location: selection.location + replacement.utf16.count, length: 0))
    case .codeBlock:
      let block = lineRange(in: text, selection: selection)
      let content = text.substring(with: block)
      let newline = source.contains("\r\n") ? "\r\n" : "\n"
      let fence = String(repeating: "`", count: max(3, longestBacktickRun(content) + 1))
      let endsLine = content.utf16.last == 10 || content.utf16.last == 13
      let terminator = endsLine ? "" : newline
      let trailing = endsLine ? newline : ""
      let opening = fence + newline
      return Edit(
        range: block, expected: content,
        replacement: opening + content + terminator + fence + trailing,
        selection: NSRange(
          location: block.location + opening.utf16.count, length: content.utf16.count))
    case .heading, .bulletList, .numberedList, .checklist, .quote:
      return lines(format, in: source, selection: selection)
    }
  }

  private static func unwrappedCode(
    in source: String, selection: NSRange, selected: String
  ) -> Edit? {
    let text = source as NSString
    var opening = selection.location
    var closing = NSMaxRange(selection)
    var padding = 0
    if opening > 1, closing + 1 < text.length,
      text.character(at: opening - 1) == 32, text.character(at: closing) == 32,
      text.character(at: opening - 2) == 96, text.character(at: closing + 1) == 96
    {
      opening -= 1
      closing += 1
      padding = 1
    }
    while opening > 0, text.character(at: opening - 1) == 96 { opening -= 1 }
    while closing < text.length, text.character(at: closing) == 96 { closing += 1 }
    let before = selection.location - opening - padding
    if before > longestBacktickRun(selected), closing - NSMaxRange(selection) - padding == before {
      let enclosing = NSRange(location: opening, length: closing - opening)
      return Edit(
        range: enclosing, expected: text.substring(with: enclosing), replacement: selected,
        selection: NSRange(location: opening, length: selected.utf16.count))
    }
    let ticks = selected.prefix { $0 == "`" }.count
    guard ticks > 0, selected.reversed().prefix(while: { $0 == "`" }).count == ticks,
      selected.utf16.count >= ticks * 2
    else { return nil }
    var content = String(selected.dropFirst(ticks).dropLast(ticks))
    guard longestBacktickRun(content) < ticks else { return nil }
    if content.hasPrefix(" "), content.hasSuffix(" "), !content.allSatisfy(\.isWhitespace) {
      content = String(content.dropFirst().dropLast())
    }
    return Edit(
      range: selection, expected: selected, replacement: content,
      selection: NSRange(location: selection.location, length: content.utf16.count))
  }

  private static func wrapped(
    _ marker: String, source: String, selection: NSRange, selected: String
  ) -> Edit {
    let text = source as NSString
    let count = marker.utf16.count
    let italicSelection =
      marker != "*"
      || (selected.prefix(while: { $0 == "*" }).count % 2 == 1
        && selected.reversed().prefix(while: { $0 == "*" }).count % 2 == 1)
    if selected.utf16.count >= count * 2, selected.hasPrefix(marker), selected.hasSuffix(marker),
      italicSelection
    {
      let content = (selected as NSString).substring(
        with: NSRange(location: count, length: selected.utf16.count - count * 2))
      return Edit(
        range: selection, expected: selected, replacement: content,
        selection: NSRange(location: selection.location, length: content.utf16.count))
    }
    let italicSurroundings =
      marker != "*"
      || ((selection.location < 2 || text.character(at: selection.location - 2) != 42)
        && (NSMaxRange(selection) + 1 >= text.length
          || text.character(at: NSMaxRange(selection) + 1) != 42))
    if selection.location >= count, NSMaxRange(selection) + count <= text.length,
      text.substring(with: NSRange(location: selection.location - count, length: count)) == marker,
      text.substring(with: NSRange(location: NSMaxRange(selection), length: count)) == marker,
      italicSurroundings
    {
      let enclosing = NSRange(
        location: selection.location - count, length: selection.length + count * 2)
      return Edit(
        range: enclosing, expected: text.substring(with: enclosing), replacement: selected,
        selection: NSRange(location: enclosing.location, length: selected.utf16.count))
    }
    return Edit(
      range: selection, expected: selected, replacement: marker + selected + marker,
      selection: NSRange(location: selection.location + count, length: selection.length))
  }

  private static func lines(
    _ format: Format, in source: String, selection: NSRange
  ) -> Edit? {
    let text = source as NSString
    let block = lineRange(in: text, selection: selection)
    let content = text.substring(with: block)
    var components = content.components(separatedBy: "\n")
    if content.utf16.last == 10 { components.removeLast() }
    let expression: NSRegularExpression
    switch format {
    case .heading:
      expression = headingPrefix
    case .quote:
      expression = quotePrefix
    default:
      expression = listPrefix
    }
    var offset = block.location
    var prefixes: [(range: NSRange, marker: String, matches: Bool)] = []
    var suffixes: [NSRange] = []
    for (index, line) in components.enumerated() {
      let value = line as NSString
      let indent = line.prefix { $0 == " " || $0 == "\t" }.utf16.count
      let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: value.length))
      let length = match.map { $0.range.length - indent } ?? 0
      let existing = value.substring(with: NSRange(location: indent, length: length))
      let marker: String
      let matches: Bool
      switch format {
      case .heading(let level):
        marker = level == 0 ? "" : String(repeating: "#", count: level) + " "
        matches =
          existing.trimmingCharacters(in: .whitespaces)
          == marker.trimmingCharacters(in: .whitespaces)
      case .bulletList:
        marker = "- "
        matches = !existing.contains("[") && ["- ", "* ", "+ "].contains(existing)
      case .numberedList:
        marker = "\(index + 1). "
        matches = existing.first?.isNumber == true
      case .checklist:
        marker = existing.contains("[x]") || existing.contains("[X]") ? "- [x] " : "- [ ] "
        matches = existing.contains("[")
      default:
        marker = "> "
        matches = existing.hasPrefix(">")
      }
      prefixes.append(
        (NSRange(location: offset + indent, length: length), marker, matches))
      if case .heading = format, let match,
        let suffix = headingSuffix.firstMatch(
          in: line, range: NSRange(location: 0, length: value.length)),
        suffix.range.location >= NSMaxRange(match.range)
      {
        suffixes.append(
          NSRange(location: offset + suffix.range.location, length: suffix.range.length))
      }
      offset += value.length + 1
    }
    let remove = prefixes.allSatisfy(\.matches)
    let changes =
      (prefixes.map { (range: $0.range, replacement: remove ? "" : $0.marker) }
      + suffixes.map { (range: $0, replacement: "") })
      .sorted { $0.range.location < $1.range.location }
    let edit = Edit(
      range: block, expected: content, replacements: changes, selection: selection)
    return edit.replacement.utf8.elementsEqual(content.utf8) ? nil : edit
  }

  static func lineRange(in source: NSString, selection: NSRange) -> NSRange {
    let first = source.lineRange(for: NSRange(location: selection.location, length: 0))
    let last = source.lineRange(
      for: NSRange(location: max(selection.location, NSMaxRange(selection) - 1), length: 0))
    return NSUnionRange(first, last)
  }

  private static func longestBacktickRun(_ source: String) -> Int {
    var longest = 0
    var current = 0
    for character in source {
      current = character == "`" ? current + 1 : 0
      longest = max(longest, current)
    }
    return longest
  }

  static func expression(_ pattern: String) -> NSRegularExpression {
    do { return try NSRegularExpression(pattern: pattern) } catch {
      preconditionFailure("Invalid built-in formatting expression: \(error)")
    }
  }

  private static let headingPrefix = expression("^[ \\t]*#{1,6}(?:[ \\t]+|(?=\\r?$))")
  private static let headingSuffix = expression("[ \\t]+#+[ \\t]*(?=\\r?$)")
  private static let quotePrefix = expression("^[ \\t]*>[ \\t]?")
  private static let listPrefix = expression(
    "^[ \\t]*(?:[-*+][ \\t]+(?:\\[[ xX]\\][ \\t]+)?|[0-9]{1,9}[.)][ \\t]+)")
}
