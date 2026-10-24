import Foundation

public enum MarkdownSyntax {
  public enum Kind: Sendable {
    case heading, code, frontmatter, link, task, checkedTask, punctuation, linkDestination
  }

  public struct Span: Sendable {
    public let range: NSRange
    public let kind: Kind
  }

  private static let inlinePatterns: [(NSRegularExpression, [(Int, Kind)])] = {
    let patterns: [(String, [(Int, Kind)])] = [
      (
        "^ {0,3}(#{1,6})(?:[ \\t]+(.*?))?(?:[ \\t]+(#+))?[ \\t]*$",
        [(1, .punctuation), (2, .heading), (3, .punctuation)]
      ),
      (
        "(!?\\[)([^\\]\\n]+)(\\]\\()([^\\)\\n]+)(\\))",
        [
          (1, .punctuation), (2, .link), (3, .punctuation), (4, .linkDestination),
          (5, .punctuation),
        ]
      ),
      (
        "(\\[\\[)([^\\]\\n]+)(\\]\\])",
        [(1, .punctuation), (2, .link), (3, .punctuation)]
      ),
      ("^[ \\t]*(?:>[ \\t]*)*[-*+][ \\t]+(\\[[ xX]\\])", [(1, .task)]),
      ("^[ \\t]*(?:>[ \\t]*)*((?:[-*+]|[0-9]{1,9}[.)]))(?=[ \\t])", [(1, .punctuation)]),
      ("^(?:[ \\t]*>)+", [(0, .punctuation)]),
      (
        "(?<!\\\\)(\\*{1,3}|_{1,3}|~~)(?=\\S)(.+?\\S|\\S)(\\1)",
        [(1, .punctuation), (3, .punctuation)]
      ),
    ]
    return patterns.map { pattern, captures in
      do {
        return (try NSRegularExpression(pattern: pattern), captures)
      } catch {
        preconditionFailure("Invalid built-in Markdown highlighting expression: \(error)")
      }
    }
  }()

  private static let fencePatterns: (opening: NSRegularExpression, closing: NSRegularExpression) = {
    do {
      return (
        try NSRegularExpression(
          pattern: "^[ \\t]*(?:>[ \\t]*)*(?:(?:[-+*]|[0-9]{1,9}[.)])[ \\t]+)?(`{3,}|~{3,})(.*)$"),
        try NSRegularExpression(pattern: "^[ \\t]*(?:>[ \\t]*)*(`{3,}|~{3,})[ \\t]*$")
      )
    } catch {
      preconditionFailure("Invalid built-in Markdown fence expression: \(error)")
    }
  }()

  public static func spans(in text: String) -> [Span] {
    let source = text as NSString
    var result: [Span] = []
    var codeDelimiters: [Span] = []
    var proseRanges: [NSRange] = []
    var proseStart: Int?
    var offset = 0
    var fence: (character: unichar, length: Int)?
    var frontmatter = false
    while offset < source.length {
      let range = source.lineRange(for: NSRange(location: offset, length: 0))
      let line = source.substring(with: range).trimmingCharacters(in: .newlines)
      let candidate = fencePatterns.opening.firstMatch(
        in: line, range: NSRange(location: 0, length: (line as NSString).length))
      var protectedKind: Kind?
      var fenceDelimiter: NSRange?
      if offset == 0 && line == "---" {
        frontmatter = true
        protectedKind = .frontmatter
      } else if frontmatter {
        protectedKind = .frontmatter
        if line == "---" || line == "..." { frontmatter = false }
      } else if let currentFence = fence {
        protectedKind = .code
        if let closing = fencePatterns.closing.firstMatch(
          in: line, range: NSRange(location: 0, length: (line as NSString).length))
        {
          let delimiter = (line as NSString).substring(with: closing.range(at: 1)) as NSString
          if delimiter.character(at: 0) == currentFence.character,
            delimiter.length >= currentFence.length
          {
            fence = nil
            fenceDelimiter = closing.range(at: 1)
          }
        }
      } else if let candidate {
        let delimiter = (line as NSString).substring(with: candidate.range(at: 1)) as NSString
        let suffix = (line as NSString).substring(with: candidate.range(at: 2))
        if delimiter.character(at: 0) != 0x60 || !suffix.contains("`") {
          fence = (delimiter.character(at: 0), delimiter.length)
          protectedKind = .code
          fenceDelimiter = candidate.range(at: 1)
        }
      }
      if protectedKind != nil || line.trimmingCharacters(in: .whitespaces).isEmpty {
        if let start = proseStart {
          proseRanges.append(NSRange(location: start, length: offset - start))
          proseStart = nil
        }
      } else if proseStart == nil {
        proseStart = offset
      }
      if let protectedKind {
        result.append(Span(range: range, kind: protectedKind))
        if let delimiter = fenceDelimiter {
          codeDelimiters.append(
            Span(
              range: NSRange(location: offset + delimiter.location, length: delimiter.length),
              kind: .punctuation))
        }
      } else {
        for (expression, captures) in inlinePatterns {
          for match in expression.matches(
            in: line, range: NSRange(location: 0, length: (line as NSString).length))
          {
            for (group, kind) in captures {
              let range = match.range(at: group)
              guard range.location != NSNotFound, range.length > 0 else { continue }
              let actualKind: Kind =
                kind == .task && (line as NSString).substring(with: range) != "[ ]"
                ? .checkedTask : kind
              result.append(
                Span(
                  range: NSRange(location: offset + range.location, length: range.length),
                  kind: actualKind))
            }
          }
        }
      }
      offset = NSMaxRange(range)
    }
    if let proseStart {
      proseRanges.append(NSRange(location: proseStart, length: source.length - proseStart))
    }
    for range in proseRanges {
      for code in inlineCodeRanges(in: source, range: range) {
        result.append(Span(range: code, kind: .code))
        var length = 0
        while length < code.length, source.character(at: code.location + length) == 0x60 {
          length += 1
        }
        for location in [code.location, NSMaxRange(code) - length] {
          codeDelimiters.append(
            Span(range: NSRange(location: location, length: length), kind: .punctuation))
        }
      }
    }
    return result + codeDelimiters
  }

  public static func ignoredWritingToolsRanges(in text: String, enclosing range: NSRange)
    -> [NSRange]
  {
    let protected = spans(in: text).compactMap { span -> NSRange? in
      guard span.kind == .code || span.kind == .frontmatter else { return nil }
      let intersection = NSIntersectionRange(span.range, range)
      return intersection.length > 0 ? intersection : nil
    }.sorted { $0.location < $1.location }
    return protected.reduce(into: []) { result, next in
      if let previous = result.last, NSMaxRange(previous) >= next.location {
        result[result.count - 1] = NSUnionRange(previous, next)
      } else {
        result.append(next)
      }
    }
  }

  private static func inlineCodeRanges(in source: NSString, range: NSRange) -> [NSRange] {
    var runs: [(range: NSRange, escaped: Bool)] = []
    var offset = range.location
    while offset < NSMaxRange(range) {
      guard source.character(at: offset) == 0x60 else {
        offset += 1
        continue
      }
      let start = offset
      while offset < NSMaxRange(range), source.character(at: offset) == 0x60 { offset += 1 }
      var preceding = start
      while preceding > range.location, source.character(at: preceding - 1) == 0x5C {
        preceding -= 1
      }
      runs.append((NSRange(location: start, length: offset - start), (start - preceding) % 2 == 1))
    }
    var nextByLength: [Int: Int] = [:]
    var closingIndices = [Int?](repeating: nil, count: runs.count)
    for index in runs.indices.reversed() {
      let run = runs[index]
      closingIndices[index] = nextByLength[run.range.length - (run.escaped ? 1 : 0)]
      nextByLength[run.range.length] = index
    }
    var result: [NSRange] = []
    var index = 0
    while index < runs.count {
      let run = runs[index]
      if run.range.length > (run.escaped ? 1 : 0), let closing = closingIndices[index] {
        let start = run.range.location + (run.escaped ? 1 : 0)
        result.append(NSRange(location: start, length: NSMaxRange(runs[closing].range) - start))
        index = closing + 1
      } else {
        index += 1
      }
    }
    return result
  }
}

public struct SourceMutation: Sendable {
  public let range: NSRange
  public let expected: String
  public let replacement: String

  public init(range: NSRange, expected: String, replacement: String) {
    self.range = range
    self.expected = expected
    self.replacement = replacement
  }

  public func applying(to source: String) throws -> String {
    let utf16 = source as NSString
    guard range.location >= 0, range.length >= 0,
      range.location <= utf16.length,
      range.length <= utf16.length - range.location
    else {
      throw MutationError.invalidRange
    }
    for boundary in [range.location, NSMaxRange(range)]
    where boundary > 0 && boundary < utf16.length {
      let previous = utf16.character(at: boundary - 1)
      let next = utf16.character(at: boundary)
      guard !(0xD800...0xDBFF).contains(previous) || !(0xDC00...0xDFFF).contains(next) else {
        throw MutationError.invalidRange
      }
    }
    guard let swiftRange = Range(range, in: source) else { throw MutationError.invalidRange }
    guard source[swiftRange].utf8.elementsEqual(expected.utf8) else {
      throw MutationError.sourceChanged
    }
    return source.replacingCharacters(in: swiftRange, with: replacement)
  }

  public enum MutationError: Error, Equatable {
    case invalidRange
    case sourceChanged
    case staleGeneration
    case compositionActive
    case documentMismatch
  }
}
