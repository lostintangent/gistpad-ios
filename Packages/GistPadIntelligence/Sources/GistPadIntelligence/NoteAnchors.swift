import Foundation

public struct NoteReplacementCandidate: Sendable {
  public let quote: String
  public let replacement: String?
  public let reason: String
  public let before: String
  public let after: String
  let isInsertion: Bool

  public init(
    quote: String, replacement: String?, reason: String, before: String = "", after: String = ""
  ) {
    self.quote = quote
    self.replacement = replacement
    self.reason = reason
    self.before = before
    self.after = after
    self.isInsertion = false
  }

  init(inserting text: String, reason: String) {
    quote = ""
    replacement = text
    self.reason = reason
    before = ""
    after = ""
    isInsertion = true
  }
}

public enum NoteAnchorRejection: Sendable, Equatable {
  case notFound, ambiguous, overlapping, invalidRange
}

public struct NoteProposalComment: Identifiable, Sendable {
  public let id: UUID
  public let quote: String
  public let replacement: String?
  public let reason: String
  public let range: NSRange?
  public let rejection: NoteAnchorRejection?

  public var canApply: Bool {
    range != nil && rejection == nil
      && replacement.map { !quote.utf8.elementsEqual($0.utf8) } == true
  }
}

public struct NoteDiffLine: Sendable {
  public enum Kind: Sendable { case unchanged, removed, added }
  public let kind: Kind
  public let text: String
}

public struct NoteProposal: Sendable {
  public let snapshot: NoteSnapshot
  public let comments: [NoteProposalComment]
  fileprivate let safetyInstruction: String?

  public var omittedCount: Int { comments.filter { $0.rejection != nil }.count }
  public var canApply: Bool { comments.contains { $0.canApply } }

  public init(snapshot: NoteSnapshot, candidates: [NoteReplacementCandidate]) {
    self.init(
      snapshot: snapshot,
      scopedCandidates: candidates.map {
        ($0, NSRange(location: 0, length: snapshot.source.utf16.count))
      })
  }

  init(
    snapshot: NoteSnapshot, scopedCandidates: [(NoteReplacementCandidate, NSRange)],
    safetyInstruction: String? = nil
  ) {
    self.snapshot = snapshot
    self.safetyInstruction = safetyInstruction
    var anchored = scopedCandidates.map { candidate, scope in
      let matches =
        candidate.isInsertion && scope.length == 0 && Range(scope, in: snapshot.source) != nil
        ? [scope]
        : NoteAnchors.matches(
          candidate.quote, in: snapshot.source, within: scope,
          before: candidate.before, after: candidate.after, allowEmptyNote: true)
      let rejection: NoteAnchorRejection?
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
      return NoteProposalComment(
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
      anchored[index] = NoteProposalComment(
        id: comment.id, quote: comment.quote, replacement: comment.replacement,
        reason: comment.reason, range: nil, rejection: .overlapping)
    }
    comments = anchored
  }

  init(
    snapshot: NoteSnapshot, comments: [NoteProposalComment], safetyInstruction: String? = nil
  ) {
    self.snapshot = snapshot
    self.comments = comments
    self.safetyInstruction = safetyInstruction
  }

  public func application(
    to current: NoteSnapshot, commentID: UUID? = nil
  ) throws -> NoteApplication {
    guard current == snapshot else { throw NoteIntelligenceError.staleSnapshot }
    let selected = comments.filter { $0.canApply && (commentID == nil || $0.id == commentID) }
    guard !selected.isEmpty else { throw NoteIntelligenceError.noApplicableChanges }
    var source = snapshot.source
    for comment in selected.sorted(by: { ($0.range?.location ?? 0) > ($1.range?.location ?? 0) }) {
      guard let range = comment.range, let replacement = comment.replacement,
        let swiftRange = Range(range, in: source),
        source[swiftRange].utf8.elementsEqual(comment.quote.utf8)
      else { throw NoteIntelligenceError.staleSnapshot }
      source.replaceSubrange(swiftRange, with: replacement)
    }
    if let safetyInstruction {
      try NoteEditSafety.validate(
        source: snapshot.source, replacement: source, instruction: safetyInstruction,
        changes: selected)
    }
    return NoteApplication(
      proposal: self, source: source,
      applied: selected.sorted { ($0.range?.location ?? 0) < ($1.range?.location ?? 0) })
  }
}

public struct NoteApplication: Sendable {
  public let proposal: NoteProposal
  public let source: String
  public let applied: [NoteProposalComment]

  public var diff: [NoteDiffLine] {
    let before = Self.lines(proposal.snapshot.source)
    let after = Self.lines(source)
    let difference = after.difference(from: before) { $0.utf8.elementsEqual($1.utf8) }
    var removals = Set<Int>()
    var insertions = Set<Int>()
    for change in difference {
      switch change {
      case .remove(let offset, _, _): removals.insert(offset)
      case .insert(let offset, _, _): insertions.insert(offset)
      }
    }
    var old = 0
    var new = 0
    var result: [NoteDiffLine] = []
    while old < before.count || new < after.count {
      if old < before.count && removals.contains(old) {
        result.append(NoteDiffLine(kind: .removed, text: before[old]))
        old += 1
      } else if new < after.count && insertions.contains(new) {
        result.append(NoteDiffLine(kind: .added, text: after[new]))
        new += 1
      } else if old < before.count && new < after.count {
        result.append(NoteDiffLine(kind: .unchanged, text: before[old]))
        old += 1
        new += 1
      } else {
        preconditionFailure("A computed source difference must consume both sequences.")
      }
    }
    return result
  }

  public func mappedSelection(_ selection: NSRange) throws -> NSRange {
    guard Range(selection, in: proposal.snapshot.source) != nil else {
      throw NoteIntelligenceError.invalidSelection
    }
    let start = mappedOffset(selection.location, trailing: selection.length == 0)
    let end = mappedOffset(NSMaxRange(selection), trailing: true)
    return NSRange(location: start, length: max(0, end - start))
  }

  public func remainingReview(on snapshot: NoteSnapshot) throws -> NoteProposal {
    let original = proposal.snapshot
    guard snapshot.documentID == original.documentID, snapshot.sessionID == original.sessionID,
      snapshot.generation == original.generation &+ 1,
      snapshot.source.utf8.elementsEqual(source.utf8)
    else { throw NoteIntelligenceError.staleSnapshot }
    let appliedIDs = Set(applied.map(\.id))
    let remaining = proposal.comments.filter { !appliedIDs.contains($0.id) }.map { comment in
      let range = comment.range.map {
        NSRange(location: mappedOffset($0.location, trailing: false), length: $0.length)
      }
      let verified =
        range.flatMap { Range($0, in: source) }.map {
          source[$0].utf8.elementsEqual(comment.quote.utf8)
        } ?? false
      return NoteProposalComment(
        id: comment.id, quote: comment.quote, replacement: comment.replacement,
        reason: comment.reason, range: verified ? range : nil,
        rejection: verified ? nil : (comment.rejection ?? .notFound))
    }
    return NoteProposal(
      snapshot: snapshot, comments: remaining,
      safetyInstruction: proposal.safetyInstruction)
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

  private static func lines(_ source: String) -> [String] {
    var result: [String] = []
    var start = source.startIndex
    for index in source.indices where source[index].isNewline {
      let end = source.index(after: index)
      result.append(String(source[start..<end]))
      start = end
    }
    if start != source.endIndex { result.append(String(source[start...])) }
    return result
  }
}

enum NoteAnchors {
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
