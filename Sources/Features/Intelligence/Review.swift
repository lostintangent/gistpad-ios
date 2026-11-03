import Foundation

package struct ModelReplacement: Sendable {
  let quote: String
  let replacement: String?
  let reason: String
  var before = ""
  var after = ""
  var isInsertion = false
}

extension ModelReplacement {
  init(inserting text: String, reason: String) {
    self.init(quote: "", replacement: text, reason: reason, isInsertion: true)
  }
}

enum AnchorRejection: Sendable, Equatable {
  case notFound, ambiguous, overlapping, invalidRange
}

package struct Review: Sendable {
  let snapshot: FileSnapshot
  let comments: [Comment]
  fileprivate let safetyInstruction: String?

  package var omittedCount: Int { comments.filter { $0.rejection != nil }.count }
  var canApply: Bool { comments.contains { $0.canApply } }

  init(snapshot: FileSnapshot, candidates: [ModelReplacement]) {
    self.init(
      snapshot: snapshot,
      scopedCandidates: candidates.map {
        ($0, NSRange(location: 0, length: snapshot.source.utf16.count))
      })
  }

  init(
    snapshot: FileSnapshot, scopedCandidates: [(ModelReplacement, NSRange)],
    safetyInstruction: String? = nil
  ) {
    self.snapshot = snapshot
    self.safetyInstruction = safetyInstruction
    var anchored = scopedCandidates.map { candidate, scope in
      let matches =
        candidate.isInsertion && scope.length == 0 && Range(scope, in: snapshot.source) != nil
        ? [scope]
        : Anchors.matches(
          candidate.quote, in: snapshot.source, within: scope,
          before: candidate.before, after: candidate.after, allowEmptyNote: true)
      let rejection: AnchorRejection?
      if (candidate.quote.isEmpty && !snapshot.source.isEmpty && !candidate.isInsertion)
        || Range(scope, in: snapshot.source) == nil
      {
        rejection = .invalidRange
      } else if matches.isEmpty {
        rejection = .notFound
      } else if matches.count > 1 {
        rejection = .ambiguous
      } else {
        rejection = nil
      }
      return Comment(
        id: UUID(), quote: candidate.quote, replacement: candidate.replacement,
        reason: candidate.reason, range: rejection == nil ? matches.first : nil,
        rejection: rejection)
    }
    var overlapping = Set<Int>()
    for first in anchored.indices {
      guard let left = anchored[first].range else { continue }
      for second in anchored.indices where second > first {
        guard let right = anchored[second].range,
          NSIntersectionRange(left, right).length > 0
            || (left.length == 0 && right.length == 0 && left.location == right.location)
            || (left.length == 0 && right.location <= left.location
              && left.location <= NSMaxRange(right))
            || (right.length == 0 && left.location <= right.location
              && right.location <= NSMaxRange(left))
        else { continue }
        overlapping.insert(first)
        overlapping.insert(second)
      }
    }
    for index in overlapping {
      let comment = anchored[index]
      anchored[index] = Comment(
        id: comment.id, quote: comment.quote, replacement: comment.replacement,
        reason: comment.reason, range: nil, rejection: .overlapping)
    }
    comments = anchored
  }

  init(
    snapshot: FileSnapshot, comments: [Comment], safetyInstruction: String? = nil
  ) {
    self.snapshot = snapshot
    self.comments = comments
    self.safetyInstruction = safetyInstruction
  }

  func dismissing(commentID: UUID) throws -> Review {
    guard comments.contains(where: { $0.id == commentID }) else {
      throw IntelligenceError.noApplicableChanges
    }
    return Review(
      snapshot: snapshot, comments: comments.filter { $0.id != commentID },
      safetyInstruction: safetyInstruction)
  }

  package func application(
    to current: FileSnapshot, commentID: UUID? = nil
  ) throws -> Applied {
    guard current == snapshot else { throw IntelligenceError.staleSnapshot }
    let selected = comments.filter { $0.canApply && (commentID == nil || $0.id == commentID) }
    guard !selected.isEmpty else { throw IntelligenceError.noApplicableChanges }
    var source = snapshot.source
    for comment in selected.sorted(by: { ($0.range?.location ?? 0) > ($1.range?.location ?? 0) }) {
      guard let range = comment.range, let replacement = comment.replacement,
        let swiftRange = Range(range, in: source),
        source[swiftRange].utf8.elementsEqual(comment.quote.utf8)
      else { throw IntelligenceError.staleSnapshot }
      source.replaceSubrange(swiftRange, with: replacement)
    }
    try validateApplication(source, changes: selected)
    return Applied(
      review: self, source: source,
      applied: selected.sorted { ($0.range?.location ?? 0) < ($1.range?.location ?? 0) })
  }

  private func validateApplication(_ replacement: String, changes: [Comment]) throws {
    let source = snapshot.source
    guard let safetyInstruction, !source.isEmpty else { return }
    if let target = EditBlock.moveTarget(in: safetyInstruction) {
      let original = EditBlock.indexed(in: source).filter {
        $0.kind == .listItem && $0.text.localizedCaseInsensitiveContains(target)
      }
      if !original.isEmpty {
        guard original.count == 1 else { throw IntelligenceError.invalidEdit }
        let result = EditBlock.indexed(in: replacement)
        let matching = result.filter {
          $0.kind == .listItem && $0.text.localizedCaseInsensitiveContains(target)
        }
        guard matching.count == 1 else { throw IntelligenceError.invalidEdit }
        let originalBody = try Self.listItemBody(original[0])
        let revisedBody = try Self.listItemBody(matching[0])
        guard revisedBody.utf8.elementsEqual(originalBody.utf8),
          !matching[0].heading.utf8.elementsEqual(original[0].heading.utf8),
          result.contains(where: {
            $0.kind == .heading && $0.text.utf8.elementsEqual(original[0].heading.utf8)
          })
        else { throw IntelligenceError.invalidEdit }
      }
    }
    let request = Self.normalized(safetyInstruction)
    for change in changes {
      if let replacement = change.replacement, !request.isEmpty,
        Self.normalized(replacement) == request
      {
        throw IntelligenceError.unsafeEdit
      }
    }
    guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw IntelligenceError.unsafeEdit
    }
    let originalCount = source.filter { !$0.isWhitespace }.count
    let replacementCount = replacement.filter { !$0.isWhitespace }.count
    guard replacementCount <= min(12, originalCount / 4) else { return }
    let retained = TextDiff(before: source, after: replacement).before
      .filter { $0.kind == .unchanged }.reduce(0) { $0 + $1.text.utf8.count }
    if retained * 10 < source.utf8.count {
      throw IntelligenceError.unsafeEdit
    }
  }

  private static func normalized(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
      .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
  }

  private static func listItemBody(_ item: EditBlock) throws -> String {
    guard let marker = item.marker else { throw IntelligenceError.invalidEdit }
    let start = (item.taskMarker?.location ?? NSMaxRange(marker)) - item.range.location
    return (item.text as NSString).substring(from: start)
  }
}

extension Review {
  package struct Comment: Identifiable, Sendable {
    package let id: UUID
    let quote: String
    let replacement: String?
    let reason: String
    let range: NSRange?
    let rejection: AnchorRejection?

    var canApply: Bool {
      range != nil && rejection == nil
        && replacement.map { !quote.utf8.elementsEqual($0.utf8) } == true
    }
  }
}

extension Review {
  package struct Applied: Sendable {
    package let review: Review
    package let source: String
    package let applied: [Comment]

    func mappedSelection(_ selection: NSRange) throws -> NSRange {
      guard Range(selection, in: review.snapshot.source) != nil else {
        throw IntelligenceError.invalidSelection
      }
      let start = mappedOffset(selection.location, trailing: selection.length == 0)
      let end = mappedOffset(NSMaxRange(selection), trailing: true)
      return NSRange(location: start, length: max(0, end - start))
    }

    func remainingReview(on snapshot: FileSnapshot) throws -> Review {
      let original = review.snapshot
      guard snapshot.fileID == original.fileID, snapshot.sessionID == original.sessionID,
        snapshot.generation == original.generation &+ 1,
        snapshot.source.utf8.elementsEqual(source.utf8)
      else { throw IntelligenceError.staleSnapshot }
      let appliedIDs = Set(applied.map(\.id))
      let remaining = review.comments.filter { !appliedIDs.contains($0.id) }.map { comment in
        let range = comment.range.map {
          NSRange(location: mappedOffset($0.location, trailing: false), length: $0.length)
        }
        let verified =
          range.flatMap { Range($0, in: source) }.map {
            source[$0].utf8.elementsEqual(comment.quote.utf8)
          } ?? false
        return Comment(
          id: comment.id, quote: comment.quote, replacement: comment.replacement,
          reason: comment.reason, range: verified ? range : nil,
          rejection: verified ? nil : (comment.rejection ?? .notFound))
      }
      return Review(
        snapshot: snapshot, comments: remaining,
        safetyInstruction: review.safetyInstruction)
    }

    private func mappedOffset(_ position: Int, trailing: Bool) -> Int {
      var shift = 0
      var mapped: Int?
      for change in applied {
        guard let range = change.range, let replacement = change.replacement else { continue }
        if position < range.location { break }
        if position < NSMaxRange(range) {
          mapped = range.location + shift + (trailing ? replacement.utf16.count : 0)
          break
        }
        shift += replacement.utf16.count - range.length
      }
      let text = source as NSString
      let offset = min(max(0, mapped ?? position + shift), text.length)
      guard offset > 0, offset < text.length else { return offset }
      let composed = text.rangeOfComposedCharacterSequence(at: offset)
      guard composed.location != offset else { return offset }
      return trailing ? NSMaxRange(composed) : composed.location
    }
  }
}

enum Anchors {
  static func matches(
    _ quote: String, in source: String, within scope: NSRange? = nil,
    before: String = "", after: String = "", allowEmptyNote: Bool = false
  ) -> [NSRange] {
    let text = source as NSString
    let scope = scope ?? NSRange(location: 0, length: text.length)
    guard Range(scope, in: source) != nil else { return [] }
    if quote.isEmpty {
      return allowEmptyNote && source.isEmpty && scope == NSRange(location: 0, length: 0)
        && before.isEmpty && after.isEmpty ? [scope] : []
    }
    var result: [NSRange] = []
    var cursor = scope.location
    while cursor < NSMaxRange(scope) {
      let search = NSRange(location: cursor, length: NSMaxRange(scope) - cursor)
      let match = text.range(of: quote, options: .literal, range: search)
      guard match.location != NSNotFound else { break }
      if let swiftRange = Range(match, in: source),
        source[swiftRange].utf8.elementsEqual(quote.utf8),
        match.location >= before.utf16.count,
        NSMaxRange(match) + after.utf16.count <= text.length
      {
        let prefix = Range(
          NSRange(location: match.location - before.utf16.count, length: before.utf16.count),
          in: source)
        let suffix = Range(
          NSRange(location: NSMaxRange(match), length: after.utf16.count), in: source)
        if let prefix, let suffix,
          source[prefix].utf8.elementsEqual(before.utf8),
          source[suffix].utf8.elementsEqual(after.utf8)
        {
          result.append(match)
        }
      }
      cursor = match.location + 1
    }
    return result
  }
}
