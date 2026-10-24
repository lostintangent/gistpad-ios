import Foundation

#if canImport(UIKit)
  import GistPadInterface
  import UIKit
#endif

public enum MarkdownSyntax {
  public enum Kind: Sendable {
    case heading, strong, emphasis, blockquote, htmlTag, strikethrough, orderedMarker
    case code, frontmatter, link, task, checkedTask, punctuation, linkDestination
  }

  public struct Span: Sendable {
    public let range: NSRange
    public let kind: Kind
  }

  private static let inlinePatterns: [(NSRegularExpression, [(Int, Kind)])] = {
    let patterns: [(String, [(Int, Kind)])] = [
      ("^ {0,3}(?:>[ \\t]*)+.*$", [(0, .blockquote)]),
      (
        "^ {0,3}#{1,6}(?:[ \\t]+.*?)?(?:[ \\t]+#+)?[ \\t]*$",
        [(0, .heading)]
      ),
      (
        #"(?<!\\)(\*{3})(?=\S)(.+?\S|\S)\1"#,
        [(0, .strong), (0, .emphasis)]
      ),
      (
        #"(?<![\\_\p{L}\p{N}])(_{3})(?=\S)(.+?\S|\S)\1(?![_\p{L}\p{N}])"#,
        [(0, .strong), (0, .emphasis)]
      ),
      (#"(?<!\\)(\*\*)(?=\S)(.+?\S|\S)\1"#, [(0, .strong)]),
      (
        #"(?<![\\_\p{L}\p{N}])(__)(?=\S)(.+?\S|\S)\1(?![_\p{L}\p{N}])"#,
        [(0, .strong)]
      ),
      (
        #"(?<![\\*])\*(?!\*)(?=\S)(.+?\S|\S)(?<!\*)\*(?!\*)|(?<![\\_\p{L}\p{N}])_(?!_)(?=\S)(.+?\S|\S)(?<!_)_(?![_\p{L}\p{N}])"#,
        [(0, .emphasis)]
      ),
      ("(?<!\\\\)(~~)(?=\\S)(.+?\\S|\\S)\\1", [(0, .strikethrough)]),
      (
        "(?<!\\\\)</?[A-Za-z][A-Za-z0-9-]*(?:[ \\t]+[^<>\\n]*?)?[ \\t]*/?>",
        [(0, .htmlTag)]
      ),
      (
        "(!?\\[)([^\\]\\n]+)(\\]\\()([^\\)\\n]+)(\\))",
        [
          (0, .link), (4, .linkDestination),
        ]
      ),
      (
        "(\\[\\[)([^\\]\\n]+)(\\]\\])",
        [(0, .link)]
      ),
      ("^[ \\t]*(?:>[ \\t]*)*[-*+][ \\t]+(\\[[ xX]\\])", [(1, .task)]),
      ("^[ \\t]*(?:>[ \\t]*)*([0-9]{1,9}[.)])(?=[ \\t])", [(1, .orderedMarker)]),
      ("^[ \\t]*(?:>[ \\t]*)*([-*+])(?=[ \\t])", [(1, .punctuation)]),
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
          }
        }
      } else if let candidate {
        let delimiter = (line as NSString).substring(with: candidate.range(at: 1)) as NSString
        let suffix = (line as NSString).substring(with: candidate.range(at: 2))
        if delimiter.character(at: 0) != 0x60 || !suffix.contains("`") {
          fence = (delimiter.character(at: 0), delimiter.length)
          protectedKind = .code
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
      }
    }
    return result
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

#if canImport(UIKit)
  @MainActor
  enum SourceSyntaxColor {
    static let emphasis = color(
      light: 0x1E293B, dark: 0xD2A8FF, highLight: 0x0F172A, highDark: 0xE6CCFF)
    static let quote = color(
      light: 0x22863A, dark: 0x7EE787, highLight: 0x155D27, highDark: 0xB0F5B7)
    static let htmlTag = color(
      light: 0x116329, dark: 0x7EE787, highLight: 0x0B4B1E, highDark: 0xB0F5B7)
    static let destination = color(
      light: 0x032F62, dark: 0xA5D6FF, highLight: 0x02234A, highDark: 0xD1ECFF)
    static let listBullet = color(
      light: 0xD4D4D4, dark: 0x525252, highLight: 0x475569, highDark: 0xE2E8F0)
    static let listNumber = color(
      light: 0x737373, dark: 0xA1A1A1, highLight: 0x475569, highDark: 0xE2E8F0)
    static let link: UIColor = {
      let ink = UIColor(InterfaceTheme.text)
      let urlColor = destination
      return UIColor { traits in
        (traits.userInterfaceStyle == .dark ? ink : urlColor).resolvedColor(with: traits)
      }
    }()

    private static func color(
      light: UInt32, dark: UInt32, highLight: UInt32, highDark: UInt32
    ) -> UIColor {
      UIColor { traits in
        let darkMode = traits.userInterfaceStyle == .dark
        let value =
          traits.accessibilityContrast == .high
          ? (darkMode ? highDark : highLight) : (darkMode ? dark : light)
        return UIColor(
          red: CGFloat((value >> 16) & 255) / 255,
          green: CGFloat((value >> 8) & 255) / 255,
          blue: CGFloat(value & 255) / 255, alpha: 1)
      }
    }
  }
#endif

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
