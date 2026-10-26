import Foundation
import OSLog

@MainActor
public final class NoteIntelligenceEngine {
  private let backend: any NoteModelBackend
  private let framingReserve = 96
  private let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "Intelligence")

  public init(backend: any NoteModelBackend) {
    self.backend = backend
  }

  public func propose(
    _ request: NoteIntelligenceRequest,
    progress: @MainActor (NoteIntelligenceProgress) -> Void = { _ in }
  ) async throws -> NoteProposal {
    guard request.action != .ask else { throw NoteIntelligenceError.invalidResponse }
    try validate(request)
    try Task.checkCancellation()
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
        let input = pass(
          request, purpose: purpose, source: chunk.source, model: model, scope: chunk.range)
        let operations: [NoteEditOperation]
        if request.action == .edit {
          operations = try await backend.editOperations(for: input)
        } else {
          operations = try await backend.replacements(for: input).map(NoteEditOperation.replace)
        }
        try Task.checkCancellation()
        for operation in operations {
          switch operation {
          case .replace(let candidate):
            if request.action == .edit, candidate.replacement == nil {
              throw NoteIntelligenceError.invalidResponse
            }
            candidates.append((candidate, chunk.range))
          case .setTaskStates(let ids, let isComplete):
            guard request.action == .edit,
              ids.map({ !$0.isEmpty && Set($0).count == $0.count }) ?? true
            else { throw NoteIntelligenceError.invalidResponse }
            let selected =
              ids.map { identifiers in
                input.tasks.filter { identifiers.contains($0.id) }
              } ?? input.tasks
            guard ids == nil || selected.count == ids?.count else {
              throw NoteIntelligenceError.invalidResponse
            }
            for task in selected where task.isComplete != isComplete {
              guard let range = Range(task.range, in: request.snapshot.source) else {
                throw NoteIntelligenceError.invalidResponse
              }
              let quote = String(request.snapshot.source[range])
              guard quote == "[ ]" || quote == "[x]" || quote == "[X]" else {
                throw NoteIntelligenceError.invalidResponse
              }
              candidates.append(
                (
                  NoteReplacementCandidate(
                    quote: quote, replacement: isComplete ? "[x]" : "[ ]",
                    reason: isComplete
                      ? String(localized: "Mark this task complete.", bundle: .module)
                      : String(localized: "Mark this task incomplete.", bundle: .module)),
                  task.range
                ))
            }
          case .deleteTasks(let ids):
            guard !ids.isEmpty, Set(ids).count == ids.count,
              ids.allSatisfy({ id in input.tasks.contains { $0.id == id } })
            else { throw NoteIntelligenceError.invalidEdit }
            for task in input.tasks where ids.contains(task.id) {
              let line = (request.snapshot.source as NSString).lineRange(for: task.range)
              let text = (request.snapshot.source as NSString).substring(with: line)
              candidates.append(
                (
                  NoteReplacementCandidate(
                    quote: text, replacement: "",
                    reason: String(localized: "Remove this task.", bundle: .module)), line
                ))
            }
          case .insertTask(let listID, let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.contains(where: \.isNewline)
            else { throw NoteIntelligenceError.invalidEdit }
            let source = request.snapshot.source as NSString
            let last = input.tasks.last { $0.listID == listID }
            guard last != nil || (listID == 0 && request.snapshot.tasks.isEmpty) else {
              throw NoteIntelligenceError.invalidEdit
            }
            let newline = request.snapshot.source.contains("\r\n") ? "\r\n" : "\n"
            let offset: Int
            let insertion: String
            if let last {
              let line = source.lineRange(for: last.range)
              offset = NSMaxRange(line)
              let prefix = source.substring(
                with: NSRange(
                  location: line.location, length: last.range.location - line.location))
              let lineText = source.substring(with: line)
              let ending = lineText.last.flatMap { $0.isNewline ? String($0) : nil }
              let taskNewline = ending ?? newline
              insertion =
                (ending == nil ? taskNewline : "") + prefix + "[ ] " + text
                + (ending == nil ? "" : taskNewline)
            } else {
              offset = source.length
              insertion =
                (source.length == 0 || request.snapshot.source.last?.isNewline == true
                  ? "" : newline) + "- [ ] " + text + newline
            }
            candidates.append(
              (
                NoteReplacementCandidate(
                  inserting: insertion,
                  reason: String(localized: "Add this task.", bundle: .module)),
                NSRange(location: offset, length: 0)
              ))
          }
        }
        completed += 1
      } catch NoteIntelligenceError.responseTooLarge, NoteIntelligenceError.insufficientContext {
        let smaller = try await split(
          chunk, request: request, purpose: purpose, model: model, force: true)
        pending.append(contentsOf: smaller.reversed())
      }
    }
    let proposal = NoteProposal(
      snapshot: request.snapshot, scopedCandidates: candidates,
      safetyInstruction: request.instruction)
    if proposal.canApply {
      _ = try proposal.application(to: request.snapshot)
    }
    return proposal
  }

  public func ask(
    _ request: NoteIntelligenceRequest,
    progress: @MainActor (NoteIntelligenceProgress) -> Void = { _ in },
    onUpdate: @MainActor ([NoteAnswerPart]) -> Void = { _ in }
  ) async throws -> NoteAnswer {
    guard request.action == .ask else { throw NoteIntelligenceError.invalidResponse }
    try validate(request)
    try Task.checkCancellation()
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
      let prose = partial.filter { $0.kind == .prose }.map(\.text).joined(separator: "\n\n")
      guard
        NoteAnswerIssue.check(
          prose, source: request.snapshot.source, instruction: request.instruction) == nil
      else { return }
      var verified: [NoteAnswerPart] = []
      for part in partial
      where !part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
    let visible = generated.filter {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !visible.isEmpty else { throw NoteIntelligenceError.emptyAnswer }
    let prose = visible.filter { $0.kind == .prose }.map(\.text).joined(separator: "\n\n")
    if let issue = NoteAnswerIssue.check(
      prose, source: request.snapshot.source, instruction: request.instruction)
    {
      throw NoteIntelligenceError.invalidAnswer(issue)
    }
    let parts = try visible.map { part -> NoteAnswerPart in
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
      let answer = pass(
        request, purpose: .answer, source: source, model: model, evidenceOnly: true,
        evidenceBlocks: evidence)
      if try await fits(answer, model: model) { return answer }
      var batches: [[String]] = []
      var batch: [String] = []
      for excerpt in evidence {
        let proposed = batch + [excerpt]
        let probe = pass(
          request, purpose: .extract, source: proposed.joined(separator: "\n\n"), model: model,
          evidenceBlocks: proposed)
        if try await fits(probe, model: model) {
          batch = proposed
        } else {
          if !batch.isEmpty { batches.append(batch) }
          batch = []
          let snapshot = NoteSnapshot(
            documentID: request.snapshot.documentID, sessionID: request.snapshot.sessionID,
            generation: request.snapshot.generation, source: excerpt)
          let extraction = NoteIntelligenceRequest(
            snapshot: snapshot, action: .ask, instruction: request.instruction, id: request.id)
          let parts = try await chunks(for: extraction, purpose: .extract, model: model)
          batches.append(contentsOf: parts.map { [$0.source] })
        }
      }
      if !batch.isEmpty { batches.append(batch) }
      var reduced: [String] = []
      for (index, batch) in batches.enumerated() {
        try Task.checkCancellation()
        progress(
          NoteIntelligenceProgress(phase: .combining, current: index + 1, total: batches.count))
        let excerpts = try await backend.excerpts(
          for: pass(
            request, purpose: .extract, source: batch.joined(separator: "\n\n"), model: model,
            evidenceBlocks: batch))
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
        pass(
          request, purpose: purpose, source: chunk.source, model: model, scope: chunk.range),
        model: model)
    {
      return [chunk]
    }
    guard chunk.source.count > 1 else { throw NoteIntelligenceError.insufficientContext }
    let midpoint = chunk.range.location + chunk.range.length / 2
    let headings = request.snapshot.headingOffsets.filter {
      $0 > chunk.range.location && $0 < NSMaxRange(chunk.range)
    }
    let heading = headings.min { abs($0 - midpoint) < abs($1 - midpoint) }
    var offset: Int
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
    let boundary = chunk.range.location + offset
    if let task = request.snapshot.tasks.first(where: {
      $0.range.location < boundary && boundary < NSMaxRange($0.range)
    }) {
      offset =
        task.range.location > chunk.range.location
        ? task.range.location - chunk.range.location : NSMaxRange(task.range) - chunk.range.location
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
    logger.notice(
      "request=\(pass.requestID.uuidString, privacy: .public) phase=\(pass.purpose.rawValue, privacy: .public) inputTokens=\(count) responseTokens=\(pass.responseTokens) context=\(model.contextSize)"
    )
    return count <= model.contextSize - pass.responseTokens - framingReserve
  }

  private func pass(
    _ request: NoteIntelligenceRequest, purpose: NoteModelPass.Purpose,
    source: String, model: NoteModelInfo, evidenceOnly: Bool = false, scope: NSRange? = nil,
    evidenceBlocks: [String]? = nil
  ) -> NoteModelPass {
    NoteModelPass(
      purpose: purpose, instruction: request.instruction, source: source,
      responseTokens: min(1_536, model.contextSize / 3), evidenceOnly: evidenceOnly,
      requestID: request.id,
      tasks: purpose == .edit
        ? request.snapshot.tasks.filter { task in
          guard let scope else { return true }
          return task.range.location >= scope.location
            && NSMaxRange(task.range) <= NSMaxRange(scope)
        } : [], evidenceBlocks: evidenceBlocks)
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
