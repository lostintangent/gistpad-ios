import Foundation

public enum MarkdownSyntax {
  public enum Kind: Sendable {
    case heading, code, frontmatter, link, task
  }

  public struct Span: Sendable {
    public let range: NSRange
    public let kind: Kind
  }

  private static let inlinePatterns: [(NSRegularExpression, Kind)] = [
    ("`[^`\\n]+`", Kind.code),
    ("\\[[^\\]\\n]+\\]\\([^\\)\\n]+\\)", .link),
    ("^\\s*[-*+] \\[[ xX]\\]", .task),
  ].map { pattern, kind in
    do {
      return (try NSRegularExpression(pattern: pattern), kind)
    } catch {
      preconditionFailure("Invalid built-in Markdown highlighting expression: \(error)")
    }
  }

  public static func spans(in text: String) -> [Span] {
    let source = text as NSString
    var result: [Span] = []
    var offset = 0
    var fence: String?
    var frontmatter = false
    while offset < source.length {
      let range = source.lineRange(for: NSRange(location: offset, length: 0))
      let line = source.substring(with: range).trimmingCharacters(in: .newlines)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if offset == 0 && line == "---" {
        frontmatter = true
        result.append(Span(range: range, kind: .frontmatter))
      } else if frontmatter {
        result.append(Span(range: range, kind: .frontmatter))
        if line == "---" || line == "..." { frontmatter = false }
      } else if let currentFence = fence {
        result.append(Span(range: range, kind: .code))
        if trimmed.hasPrefix(currentFence) { fence = nil }
      } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fence = String(trimmed.prefix(3))
        result.append(Span(range: range, kind: .code))
      } else {
        if line.range(of: "^#{1,6}\\s", options: .regularExpression) != nil {
          result.append(Span(range: range, kind: .heading))
        }
        for (expression, kind) in inlinePatterns {
          for match in expression.matches(
            in: line, range: NSRange(location: 0, length: (line as NSString).length))
          {
            result.append(
              Span(
                range: NSRange(location: offset + match.range.location, length: match.range.length),
                kind: kind))
          }
        }
      }
      offset = NSMaxRange(range)
    }
    return result
  }

  public static func ignoredWritingToolsRanges(in text: String, enclosing range: NSRange)
    -> [NSRange]
  {
    spans(in: text).compactMap { span in
      guard span.kind == .code || span.kind == .frontmatter else { return nil }
      let intersection = NSIntersectionRange(span.range, range)
      return intersection.length > 0 ? intersection : nil
    }
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
