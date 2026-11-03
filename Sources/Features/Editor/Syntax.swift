import Foundation

public enum Syntax {
  enum Kind: Sendable {
    case heading, strong, emphasis, blockquote, htmlTag, strikethrough, orderedMarker
    case code, frontmatter, link, task, checkedTask, punctuation, linkDestination
  }

  struct Span: Sendable {
    let range: NSRange
    let kind: Kind
    let isFencedCode: Bool

    init(range: NSRange, kind: Kind, isFencedCode: Bool = false) {
      self.range = range
      self.kind = kind
      self.isFencedCode = isFencedCode
    }
  }

  public struct Block: Sendable {
    public enum Kind: String, Sendable {
      case heading, paragraph, listItem, tableRow, code
    }

    public let kind: Kind
    public let range: NSRange
    public let level: Int?
    public let marker: NSRange?
    public let taskMarker: NSRange?
  }

  private static let inlinePatterns: [(NSRegularExpression, [(Int, Kind)])] = {
    let patterns: [(String, [(Int, Kind)])] = [
      ("^ {0,3}(?:>[ \\t]*)+.*$", [(0, .blockquote)]),
      ("^ {0,3}#{1,6}(?:[ \\t]+.*?)?(?:[ \\t]+#+)?[ \\t]*$", [(0, .heading)]),
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

  public static func contentStart(in text: String) -> Int {
    let source = text as NSString
    guard source.length > 0 else { return 0 }
    func line(at offset: Int) -> (text: String, end: Int) {
      var end = 0
      var contentsEnd = 0
      source.getLineStart(
        nil, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: offset, length: 0))
      return (source.substring(with: NSRange(location: offset, length: contentsEnd - offset)), end)
    }
    func isFence(_ value: String) -> Bool {
      value.hasPrefix("---") && value.dropFirst(3).allSatisfy(\.isWhitespace)
    }
    let opening = line(at: 0)
    guard isFence(opening.text) else { return 0 }
    var offset = opening.end
    while offset < source.length {
      let current = line(at: offset)
      if isFence(current.text) {
        guard current.end > offset + current.text.utf16.count else { return 0 }
        var content = current.end
        while content < source.length {
          let next = line(at: content)
          guard next.text.allSatisfy(\.isWhitespace),
            next.end > content + next.text.utf16.count
          else { break }
          content = next.end
        }
        return content
      }
      offset = current.end
    }
    return 0
  }

  /// Source blocks and markers with UTF-16 ranges, excluding fenced code and front matter.
  public static func outline(in text: String) -> (
    headings: [NSRange], taskMarkers: [NSRange], blocks: [Block],
    codeRanges: [NSRange], frontMatterRanges: [NSRange]
  ) {
    let source = text as NSString
    let spans = spans(in: text)
    let protected = spans.filter { $0.kind == .code || $0.kind == .frontmatter }
    let codeRanges = mergedRanges(spans.filter { $0.kind == .code }.map(\.range))
    let frontMatterRanges = mergedRanges(spans.filter { $0.kind == .frontmatter }.map(\.range))
    let taskMarkers = spans.filter { span in
      (span.kind == .task || span.kind == .checkedTask)
        && !protected.contains { NSIntersectionRange($0.range, span.range).length > 0 }
    }.map(\.range)
    let headings = spans.filter { span in
      span.kind == .heading
        && !protected.contains { NSIntersectionRange($0.range, span.range).length > 0 }
    }.map(\.range)
    let byLine = Dictionary(grouping: spans.filter {
      $0.kind == .heading || $0.kind == .orderedMarker || $0.kind == .punctuation
        || $0.kind == .task || $0.kind == .checkedTask || $0.kind == .frontmatter
        || $0.isFencedCode
    }) { source.lineRange(for: NSRange(location: $0.range.location, length: 0)).location }
    var blocks: [Block] = []
    var current: Block?
    func finish() {
      if let current { blocks.append(current) }
      current = nil
    }
    func append(
      _ range: NSRange, kind: Block.Kind, continuing: Bool = false,
      level: Int? = nil, marker: NSRange? = nil, taskMarker: NSRange? = nil
    ) {
      if continuing, let previous = current, previous.kind == kind {
        current = Block(
          kind: kind,
          range: NSRange(
            location: previous.range.location, length: NSMaxRange(range) - previous.range.location),
          level: previous.level, marker: previous.marker, taskMarker: previous.taskMarker)
      } else {
        finish()
        current = Block(
          kind: kind, range: range, level: level, marker: marker, taskMarker: taskMarker)
      }
    }
    var offset = 0
    while offset < source.length {
      let line = source.lineRange(for: NSRange(location: offset, length: 0))
      var end = NSMaxRange(line)
      while end > offset
        && (source.character(at: end - 1) == 10 || source.character(at: end - 1) == 13)
      {
        end -= 1
      }
      let range = NSRange(location: offset, length: end - offset)
      let value = source.substring(with: range)
      let markers = byLine[offset] ?? []
      if markers.contains(where: \.isFencedCode) {
        append(range, kind: .code, continuing: true)
      } else if markers.contains(where: { $0.kind == .frontmatter })
        || value.trimmingCharacters(in: .whitespaces).isEmpty
      {
        finish()
      } else if markers.contains(where: { $0.kind == .heading && headings.contains($0.range) }) {
        append(
          range, kind: .heading,
          level: value.trimmingCharacters(in: .whitespaces).prefix { $0 == "#" }.count)
        finish()
      } else if let marker = markers.first(where: { span in
        guard span.kind == .punctuation || span.kind == .orderedMarker,
          !codeRanges.contains(where: { NSIntersectionRange($0, span.range).length > 0 })
        else { return false }
        let indent = source.substring(
          with: NSRange(location: offset, length: span.range.location - offset))
        return indent.allSatisfy { $0 == " " || $0 == "\t" }
      }) {
        let task = markers.first { $0.kind == .task || $0.kind == .checkedTask }
        var prefixEnd = NSMaxRange(task?.range ?? marker.range)
        while prefixEnd < end,
          source.character(at: prefixEnd) == 32 || source.character(at: prefixEnd) == 9
        {
          prefixEnd += 1
        }
        append(
          range, kind: .listItem,
          marker: NSRange(location: offset, length: prefixEnd - offset),
          taskMarker: task?.range)
      } else if value.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
        append(range, kind: .tableRow)
      } else if let current,
        current.kind == .paragraph || (current.kind == .listItem && value.first?.isWhitespace == true)
      {
        append(range, kind: current.kind, continuing: true)
      } else {
        append(range, kind: .paragraph)
      }
      offset = NSMaxRange(line)
    }
    finish()
    return (headings, taskMarkers, blocks, codeRanges, frontMatterRanges)
  }

  static func spans(in text: String) -> [Span] {
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
      var isFenceLine = false
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
            isFenceLine = true
          }
        }
      } else if let candidate {
        let delimiter = (line as NSString).substring(with: candidate.range(at: 1)) as NSString
        let suffix = (line as NSString).substring(with: candidate.range(at: 2))
        if delimiter.character(at: 0) != 0x60 || !suffix.contains("`") {
          fence = (delimiter.character(at: 0), delimiter.length)
          protectedKind = .code
          isFenceLine = true
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
        result.append(Span(range: range, kind: protectedKind, isFencedCode: protectedKind == .code))
        // A fence line is markup, so it paints like other line-leading markers.
        if isFenceLine { result.append(Span(range: range, kind: .punctuation)) }
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

  static func ignoredWritingToolsRanges(in text: String, enclosing range: NSRange)
    -> [NSRange]
  {
    let protected = spans(in: text).compactMap { span -> NSRange? in
      guard span.kind == .code || span.kind == .frontmatter else { return nil }
      let intersection = NSIntersectionRange(span.range, range)
      return intersection.length > 0 ? intersection : nil
    }
    return mergedRanges(protected)
  }

  private static func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
    ranges.sorted { $0.location < $1.location }.reduce(into: []) { result, next in
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
