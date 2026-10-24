import Foundation

@MainActor
public final class NoteIntelligenceEngine {
  private let backend: any NoteModelBackend
  private let framingReserve = 96

  public init(backend: any NoteModelBackend) {
    self.backend = backend
  }

  public func propose(
    _ request: NoteIntelligenceRequest,
    progress: @MainActor (NoteIntelligenceProgress) -> Void = { _ in }
  ) async throws -> NoteProposal {
    guard request.action != .ask else { throw NoteIntelligenceError.invalidResponse }
    try validate(request)
    let model = try await backend.modelInfo()
    let purpose: NoteModelPass.Purpose = request.action == .edit ? .edit : .review
    let chunks = try await chunks(for: request, purpose: purpose, model: model)
    var candidates: [(NoteReplacementCandidate, NSRange)] = []
    var pending = Array(chunks.reversed())
    var completed = 0
    while let chunk = pending.popLast() {
      try Task.checkCancellation()
      progress(
        NoteIntelligenceProgress(
          phase: request.action == .edit ? .editing : .reviewing,
          current: completed + 1, total: completed + pending.count + 1))
      do {
        let generated = try await backend.replacements(
          for: pass(request, purpose: purpose, source: chunk.source, model: model))
        try Task.checkCancellation()
        candidates.append(contentsOf: generated.map { ($0, chunk.range) })
        completed += 1
      } catch NoteIntelligenceError.responseTooLarge, NoteIntelligenceError.insufficientContext {
        let smaller = try await split(
          chunk, request: request, purpose: purpose, model: model, force: true)
        pending.append(contentsOf: smaller.reversed())
      }
    }
    return NoteProposal(snapshot: request.snapshot, scopedCandidates: candidates)
  }

  public func ask(
    _ request: NoteIntelligenceRequest,
    progress: @MainActor (NoteIntelligenceProgress) -> Void = { _ in },
    onUpdate: @MainActor ([NoteAnswerPart]) -> Void = { _ in }
  ) async throws -> NoteAnswer {
    guard request.action == .ask else { throw NoteIntelligenceError.invalidResponse }
    try validate(request)
    let model = try await backend.modelInfo()
    let whole = pass(request, purpose: .answer, source: request.snapshot.source, model: model)
    let input: NoteModelPass
    if try await fits(whole, model: model) {
      input = whole
    } else {
      let chunks = try await chunks(for: request, purpose: .extract, model: model)
      var evidence: [String] = []
      for (index, chunk) in chunks.enumerated() {
        try Task.checkCancellation()
        progress(NoteIntelligenceProgress(phase: .reading, current: index + 1, total: chunks.count))
        let excerpts = try await backend.excerpts(
          for: pass(request, purpose: .extract, source: chunk.source, model: model))
        for excerpt in excerpts {
          guard !NoteAnchors.matches(excerpt, in: chunk.source).isEmpty else {
            throw NoteIntelligenceError.unverifiedQuotation
          }
        }
        evidence.append(contentsOf: excerpts)
      }
      evidence = unique(evidence)
      guard !evidence.isEmpty else { throw NoteIntelligenceError.noEvidence }
      input = try await combine(evidence, request: request, model: model, progress: progress)
    }
    try Task.checkCancellation()
    progress(NoteIntelligenceProgress(phase: .answering, current: 1, total: 1))
    let generated = try await backend.answer(for: input) { partial in
      var verified: [NoteAnswerPart] = []
      for part in partial {
        switch part.kind {
        case .prose:
          verified.append(.prose(part.text))
        case .quote:
          let ranges = NoteAnchors.matches(part.text, in: request.snapshot.source)
          guard !ranges.isEmpty else {
            onUpdate(verified)
            return
          }
          verified.append(.quotation(NoteCitation(quote: part.text, ranges: ranges)))
        }
      }
      onUpdate(verified)
    }
    try Task.checkCancellation()
    guard !generated.isEmpty, generated.contains(where: { !$0.text.isEmpty }) else {
      throw NoteIntelligenceError.invalidResponse
    }
    let parts = try generated.map { part -> NoteAnswerPart in
      switch part.kind {
      case .prose: return .prose(part.text)
      case .quote:
        let ranges = NoteAnchors.matches(part.text, in: request.snapshot.source)
        guard !ranges.isEmpty else { throw NoteIntelligenceError.unverifiedQuotation }
        return .quotation(NoteCitation(quote: part.text, ranges: ranges))
      }
    }
    onUpdate(parts)
    return NoteAnswer(snapshot: request.snapshot, parts: parts)
  }

  private func combine(
    _ initial: [String], request: NoteIntelligenceRequest, model: NoteModelInfo,
    progress: @MainActor (NoteIntelligenceProgress) -> Void
  ) async throws -> NoteModelPass {
    var evidence = initial
    for _ in 0..<8 {
      let source = evidence.joined(separator: "\n\n")
      let answer = pass(request, purpose: .answer, source: source, model: model)
      if try await fits(answer, model: model) { return answer }
      let snapshot = NoteSnapshot(
        documentID: request.snapshot.documentID, sessionID: request.snapshot.sessionID,
        generation: request.snapshot.generation, source: source)
      let extraction = NoteIntelligenceRequest(
        snapshot: snapshot, action: .ask, instruction: request.instruction)
      let batches = try await chunks(for: extraction, purpose: .extract, model: model)
      var reduced: [String] = []
      for (index, batch) in batches.enumerated() {
        try Task.checkCancellation()
        progress(
          NoteIntelligenceProgress(phase: .combining, current: index + 1, total: batches.count))
        let excerpts = try await backend.excerpts(
          for: pass(request, purpose: .extract, source: batch.source, model: model))
        for excerpt in excerpts {
          guard evidence.contains(where: { !NoteAnchors.matches(excerpt, in: $0).isEmpty }) else {
            throw NoteIntelligenceError.unverifiedQuotation
          }
        }
        reduced.append(contentsOf: excerpts)
      }
      reduced = unique(reduced)
      guard !reduced.isEmpty else { throw NoteIntelligenceError.noEvidence }
      guard reduced.reduce(0, { $0 + $1.utf8.count }) < evidence.reduce(0, { $0 + $1.utf8.count })
      else {
        throw NoteIntelligenceError.insufficientContext
      }
      evidence = reduced
    }
    throw NoteIntelligenceError.insufficientContext
  }

  private struct Chunk {
    let source: String
    let range: NSRange
  }

  private func chunks(
    for request: NoteIntelligenceRequest, purpose: NoteModelPass.Purpose, model: NoteModelInfo
  ) async throws -> [Chunk] {
    let source = request.snapshot.source
    let whole = Chunk(source: source, range: NSRange(location: 0, length: source.utf16.count))
    return try await split(whole, request: request, purpose: purpose, model: model)
  }

  private func split(
    _ chunk: Chunk, request: NoteIntelligenceRequest, purpose: NoteModelPass.Purpose,
    model: NoteModelInfo, force: Bool = false
  ) async throws -> [Chunk] {
    try Task.checkCancellation()
    if !force,
      try await fits(
        pass(request, purpose: purpose, source: chunk.source, model: model), model: model)
    {
      return [chunk]
    }
    guard chunk.source.count > 1 else { throw NoteIntelligenceError.insufficientContext }
    let midpoint = chunk.range.location + chunk.range.length / 2
    let headings = request.snapshot.headingOffsets.filter {
      $0 > chunk.range.location && $0 < NSMaxRange(chunk.range)
    }
    let heading = headings.min { abs($0 - midpoint) < abs($1 - midpoint) }
    let offset: Int
    if let heading, Range(NSRange(location: heading, length: 0), in: request.snapshot.source) != nil
    {
      offset = heading - chunk.range.location
    } else {
      let indices = Array(chunk.source.indices)
      let middleOffset = indices.count / 2
      let middle = indices[middleOffset]
      let newline = indices.enumerated().filter { chunk.source[$0.element].isNewline }.min {
        abs($0.offset - middleOffset) < abs($1.offset - middleOffset)
      }
      let boundary = newline.map { chunk.source.index(after: $0.element) } ?? middle
      let safeBoundary = boundary == chunk.source.endIndex ? middle : boundary
      offset = chunk.source[..<safeBoundary].utf16.count
    }
    guard offset > 0, offset < chunk.range.length else {
      throw NoteIntelligenceError.insufficientContext
    }
    let leftRange = NSRange(location: chunk.range.location, length: offset)
    let rightRange = NSRange(
      location: chunk.range.location + offset, length: chunk.range.length - offset)
    guard let left = Range(leftRange, in: request.snapshot.source),
      let right = Range(rightRange, in: request.snapshot.source)
    else { throw NoteIntelligenceError.invalidResponse }
    let first = try await split(
      Chunk(source: String(request.snapshot.source[left]), range: leftRange),
      request: request, purpose: purpose, model: model)
    let second = try await split(
      Chunk(source: String(request.snapshot.source[right]), range: rightRange),
      request: request, purpose: purpose, model: model)
    return first + second
  }

  private func fits(_ pass: NoteModelPass, model: NoteModelInfo) async throws -> Bool {
    guard model.contextSize > 0, pass.responseTokens > 0 else {
      throw NoteIntelligenceError.insufficientContext
    }
    let count = try await backend.tokenCount(for: pass)
    guard count >= 0 else { throw NoteIntelligenceError.invalidResponse }
    return count <= model.contextSize - pass.responseTokens - framingReserve
  }

  private func pass(
    _ request: NoteIntelligenceRequest, purpose: NoteModelPass.Purpose,
    source: String, model: NoteModelInfo
  ) -> NoteModelPass {
    NoteModelPass(
      purpose: purpose, instruction: request.instruction, source: source,
      responseTokens: min(1_536, model.contextSize / 3))
  }

  private func validate(_ request: NoteIntelligenceRequest) throws {
    if request.action != .review
      && request.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw NoteIntelligenceError.emptyInstruction
    }
  }

  private func unique(_ strings: [String]) -> [String] {
    var seen = Set<Data>()
    return strings.filter { seen.insert(Data($0.utf8)).inserted }
  }
}
