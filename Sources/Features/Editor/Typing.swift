import Foundation

enum Typing {
  /// Returns nil for ordinary input or protected syntax so the caller can use native input.
  static func edit(
    in source: String, selection: NSRange, replacement: String
  ) throws -> Edit? {
    let selected = try Edit.text(in: source, at: selection)
    if ["\n", "\r", "\r\n"].contains(replacement) {
      let protected = protectedRanges(in: source)
      guard !isProtected(selection, ranges: protected) else { return nil }
      return continueList(in: source, selection: selection, protected: protected)
    }
    guard !selected.isEmpty, !selected.contains(where: \.isNewline),
      !selected.allSatisfy(\.isWhitespace),
      replacement.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
      let url = URL(string: replacement),
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      let host = url.host, !host.isEmpty
    else { return nil }
    guard !isProtected(selection, ranges: protectedRanges(in: source)) else { return nil }
    let label = selected.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "[", with: "\\[")
      .replacingOccurrences(of: "]", with: "\\]")
    let destination = url.absoluteString
      .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
      .replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
    let markdown = "[\(label)](\(destination))"
    return Edit(
      range: selection, expected: selected, replacement: markdown,
      selection: NSRange(location: selection.location + markdown.utf16.count, length: 0))
  }

  /// Call only outside composition and Writing Tools. Offsets and returned selection are UTF-16.
  static func indent(
    in source: String, selection: NSRange, outdent: Bool
  ) throws -> Edit? {
    _ = try Edit.text(in: source, at: selection)
    let text = source as NSString
    let block = Formatting.lineRange(in: text, selection: selection)
    guard !isProtected(block, ranges: protectedRanges(in: source)) else { return nil }
    var changes: [(range: NSRange, replacement: String)] = []
    var offset = block.location
    repeat {
      let line = text.lineRange(for: NSRange(location: offset, length: 0))
      let value = text.substring(with: line)
      if outdent {
        let prefix = value.prefix { $0 == " " || $0 == "\t" }
        let count = prefix.first == "\t" ? 1 : prefix.prefix(2).prefix { $0 == " " }.count
        if count > 0 {
          changes.append((NSRange(location: offset, length: count), ""))
        }
      } else {
        changes.append((NSRange(location: offset, length: 0), value.hasPrefix("\t") ? "\t" : "  "))
      }
      guard line.length > 0 else { break }
      offset = NSMaxRange(line)
    } while offset < NSMaxRange(block)
    guard !changes.isEmpty else { return nil }
    return Edit(
      range: block, expected: text.substring(with: block), replacements: changes, selection: selection)
  }

  private static func continueList(
    in source: String, selection: NSRange, protected: [NSRange]
  ) -> Edit? {
    let text = source as NSString
    var lineStart = 0
    var lineEnd = 0
    var contentsEnd = 0
    text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: selection)
    guard NSMaxRange(selection) <= contentsEnd else { return nil }
    let line = text.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
    guard !line.contains(where: \.isNewline) else { return nil }
    let value = line as NSString
    guard
      let match = listPrefix.firstMatch(
        in: line, range: NSRange(location: 0, length: value.length)),
      selection.location >= lineStart + match.range.length
    else { return nil }
    let content = value.substring(from: match.range.length)
    if content.allSatisfy(\.isWhitespace) {
      let range = NSRange(location: lineStart, length: contentsEnd - lineStart)
      return Edit(
        range: range, expected: line, replacement: "",
        selection: NSRange(location: lineStart, length: 0))
    }
    func capture(_ index: Int) -> String {
      let range = match.range(at: index)
      return range.location == NSNotFound ? "" : value.substring(with: range)
    }
    let prefix: String
    if !capture(6).isEmpty {
      guard let number = Int(capture(6)), number < 999_999_999 else { return nil }
      prefix = capture(1) + String(number + 1) + capture(7) + capture(8)
    } else {
      let task = match.range(at: 4).location != NSNotFound
      prefix =
        capture(1) + capture(2) + capture(3)
        + (task ? "[ ]" + (capture(5).isEmpty ? " " : capture(5)) : "")
    }
    let newline: String
    if lineEnd > contentsEnd {
      newline = text.substring(with: NSRange(location: contentsEnd, length: lineEnd - contentsEnd))
    } else {
      newline = source.contains("\r\n") ? "\r\n" : source.contains("\r") ? "\r" : "\n"
    }
    let replacement = newline + prefix
    if !capture(6).isEmpty, let number = Int(capture(6)) {
      return continuedNumberedList(
        in: source, selection: selection, replacement: replacement, nextLine: lineEnd,
        indentation: capture(1), delimiter: capture(7), nextNumber: number + 2, protected: protected
      )
    }
    return Edit(
      range: selection, expected: text.substring(with: selection), replacement: replacement,
      selection: NSRange(location: selection.location + replacement.utf16.count, length: 0))
  }

  private static func continuedNumberedList(
    in source: String, selection: NSRange, replacement: String, nextLine: Int,
    indentation: String, delimiter: String, nextNumber: Int, protected: [NSRange]
  ) -> Edit {
    let text = source as NSString
    var changes: [(range: NSRange, replacement: String)] = [(selection, replacement)]
    var offset = nextLine
    var number = nextNumber
    while offset < text.length, number <= 999_999_999 {
      let range = text.lineRange(for: NSRange(location: offset, length: 0))
      let line = text.substring(with: range).trimmingCharacters(in: .newlines)
      let indent = String(line.prefix { $0 == " " || $0 == "\t" })
      if indent.utf16.count > indentation.utf16.count {
        offset = NSMaxRange(range)
        continue
      }
      guard indent == indentation,
        let match = listPrefix.firstMatch(
          in: line, range: NSRange(location: 0, length: line.utf16.count)),
        match.range(at: 6).location != NSNotFound,
        (line as NSString).substring(with: match.range(at: 7)) == delimiter,
        !isProtected(range, ranges: protected)
      else { break }
      let digits = match.range(at: 6)
      changes.append(
        (NSRange(location: offset + digits.location, length: digits.length), String(number)))
      number += 1
      offset = NSMaxRange(range)
    }
    let end = max(NSMaxRange(selection), changes.map { NSMaxRange($0.range) }.max() ?? 0)
    let range = NSRange(location: selection.location, length: end - selection.location)
    return Edit(
      range: range, expected: text.substring(with: range), replacements: changes,
      selection: selection)
  }

  private static func protectedRanges(in source: String) -> [NSRange] {
    // Probe the next character so an EOF caret in an unfinished block stays protected.
    Syntax.spans(in: source + "\u{FFFC}").compactMap { span in
      span.kind == .code || span.kind == .frontmatter ? span.range : nil
    }
  }

  private static func isProtected(_ range: NSRange, ranges: [NSRange]) -> Bool {
    ranges.contains { protected in
      if range.length == 0 {
        return range.location >= protected.location && range.location < NSMaxRange(protected)
      }
      return NSIntersectionRange(range, protected).length > 0
    }
  }

  private static let listPrefix = Formatting.expression(
    "^([ \\t]*)(?:([-*+])([ \\t]+)(?:\\[([ xX])\\]([ \\t]+|$))?|([0-9]{1,9})([.)])([ \\t]+))")
}
