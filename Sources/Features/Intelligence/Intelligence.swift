import Foundation
import Editor
import OSLog

@MainActor
public final class Intelligence {
  private let backend: any IntelligenceModel
  private let framingReserve = 96
  /// Real answers use under 120 tokens. A runaway repeats itself until this limit stops it.
  private let answerTokens = 384
  private let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "Intelligence")

  public init(backend: any IntelligenceModel) {
    self.backend = backend
  }

  public func edit(
    _ request: IntelligenceRequest,
    progress: @MainActor (IntelligenceProgress) -> Void = { _ in }
  ) async throws -> Review {
    guard request.action == .edit else { throw IntelligenceError.invalidResponse }
    return try await generate(request, progress: progress)
  }

  public func review(
    _ request: IntelligenceRequest,
    progress: @MainActor (IntelligenceProgress) -> Void = { _ in }
  ) async throws -> Review {
    guard request.action == .review else { throw IntelligenceError.invalidResponse }
    return try await generate(request, progress: progress)
  }

  /// Review starts chunked; Edit starts with the whole body and splits only on context failure.
  private func generate(
    _ request: IntelligenceRequest, progress: @MainActor (IntelligenceProgress) -> Void
  ) async throws -> Review {
    try validate(request)
    try Task.checkCancellation()
    let model = try await backend.modelInfo()
    let purpose: ModelPass.Purpose = request.action == .edit ? .edit : .review
    let chunks =
      purpose == .edit
      ? [content(in: request)]
      : try await chunks(for: request, purpose: purpose, model: model)
    var candidates: [(ModelReplacement, NSRange)] = []
    var pending = Array(chunks.reversed())
    var completed = 0
    while let chunk = pending.popLast() {
      try Task.checkCancellation()
      progress(
        IntelligenceProgress(
          phase: request.action == .edit ? .editing : .reviewing,
          current: completed + 1, total: completed + pending.count + 1))
      do {
        let input = pass(
          request, purpose: purpose, source: chunk.source, model: model, scope: chunk.range)
        let operations: [ModelEdit]
        if request.action == .edit {
          operations = try await backend.editOperations(for: input)
        } else {
          operations = try await backend.replacements(for: input).map(ModelEdit.replace)
        }
        try Task.checkCancellation()
        for operation in operations {
          switch operation {
          case .replace(let candidate):
            if request.action == .edit, candidate.replacement == nil {
              throw IntelligenceError.invalidResponse
            }
            candidates.append((candidate, chunk.range))
          case .setTaskStates(let ids, let isComplete):
            guard request.action == .edit,
              ids.map({ !$0.isEmpty && Set($0).count == $0.count }) ?? true
            else { throw IntelligenceError.invalidResponse }
            let selected =
              ids.map { identifiers in
                input.tasks.filter { identifiers.contains($0.id) }
              } ?? input.tasks
            guard ids == nil || selected.count == ids?.count else {
              throw IntelligenceError.invalidResponse
            }
            for task in selected where task.isComplete != isComplete {
              guard let range = Range(task.range, in: request.snapshot.source) else {
                throw IntelligenceError.invalidResponse
              }
              let quote = String(request.snapshot.source[range])
              guard quote == "[ ]" || quote == "[x]" || quote == "[X]" else {
                throw IntelligenceError.invalidResponse
              }
              candidates.append(
                (
                  ModelReplacement(
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
            else { throw IntelligenceError.invalidEdit }
            for task in input.tasks where ids.contains(task.id) {
              let line = (request.snapshot.source as NSString).lineRange(for: task.range)
              let text = (request.snapshot.source as NSString).substring(with: line)
              candidates.append(
                (
                  ModelReplacement(
                    quote: text, replacement: "",
                    reason: String(localized: "Remove this task.", bundle: .module)), line
                ))
            }
          case .insertTask(let listID, let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.contains(where: \.isNewline)
            else { throw IntelligenceError.invalidEdit }
            let source = request.snapshot.source as NSString
            let last = input.tasks.last { $0.listID == listID }
            guard last != nil || (listID == 0 && request.snapshot.tasks.isEmpty) else {
              throw IntelligenceError.invalidEdit
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
                ModelReplacement(
                  inserting: insertion,
                  reason: String(localized: "Add this task.", bundle: .module)),
                NSRange(location: offset, length: 0)
              ))
          case .rewrite(let revised):
            guard request.action == .edit else { throw IntelligenceError.invalidResponse }
            let start = min(
              max(chunk.range.location, Syntax.contentStart(in: request.snapshot.source)),
              NSMaxRange(chunk.range))
            candidates += try Revision.candidates(
              in: request.snapshot.source,
              visible: NSRange(location: start, length: NSMaxRange(chunk.range) - start),
              revised: revised)
          case .rewriteRegion(let relative, let revised):
            guard request.action == .edit,
              relative.location >= 0, relative.length > 0,
              NSMaxRange(relative) <= chunk.range.length
            else { throw IntelligenceError.invalidResponse }
            candidates += try Revision.candidates(
              in: request.snapshot.source,
              visible: NSRange(
                location: chunk.range.location + relative.location, length: relative.length),
              revised: revised)
          case .replaceRegion(let relative, let candidate):
            guard request.action == .edit,
              relative.location >= 0, relative.length > 0,
              NSMaxRange(relative) <= chunk.range.length,
              candidate.replacement != nil,
              candidate.quote.utf8.elementsEqual(
                (chunk.source as NSString).substring(with: relative).utf8)
            else { throw IntelligenceError.invalidResponse }
            candidates.append(
              (
                candidate,
                NSRange(location: chunk.range.location + relative.location, length: relative.length)
              ))
          case .deleteRegion(let relative, let replacement):
            guard request.action == .edit,
              relative.location >= 0, relative.length > 0,
              NSMaxRange(relative) <= chunk.range.length,
              replacement.isEmpty || replacement == "\n" || replacement == "\r\n"
            else { throw IntelligenceError.invalidResponse }
            let range = NSRange(
              location: chunk.range.location + relative.location, length: relative.length)
            let quote = (request.snapshot.source as NSString).substring(with: range)
            candidates.append(
              (ModelReplacement(quote: quote, replacement: replacement, reason: ""), range))
          }
        }
        completed += 1
        // Selection needs a smaller part when the response or context cannot fit.
      } catch IntelligenceError.responseTooLarge where purpose == .review,
        IntelligenceError.insufficientContext
      {
        let smaller = try await split(
          chunk, request: request, purpose: purpose, model: model, force: true)
        pending.append(contentsOf: smaller.reversed())
      }
    }
    let review = Review(
      snapshot: request.snapshot, scopedCandidates: candidates,
      safetyInstruction: request.instruction)
    if review.canApply {
      _ = try review.application(to: request.snapshot)
    }
    return review
  }

  public func ask(
    _ request: IntelligenceRequest,
    progress: @MainActor (IntelligenceProgress) -> Void = { _ in },
    onPartialAnswer: @MainActor (String) -> Void = { _ in }
  ) async throws -> Answer {
    guard request.action == .ask else { throw IntelligenceError.invalidResponse }
    try validate(request)
    try Task.checkCancellation()
    let model = try await backend.modelInfo()
    logger.notice(
      "request=\(request.id.uuidString, privacy: .public) action=ask model=\(model.variant, privacy: .public) context=\(model.contextSize)"
    )
    let body = content(in: request)
    let whole = pass(request, purpose: .answer, source: body.source, model: model)
    let input: ModelPass
    let wholeFits = try await fits(whole, model: model)
    logger.notice(
      "request=\(request.id.uuidString, privacy: .public) action=ask path=\(wholeFits ? "whole" : "extract", privacy: .public) bodyUTF16=\(body.range.length) frontMatterUTF16=\(body.range.location)"
    )
    if wholeFits {
      input = whole
    } else {
      let chunks = try await chunks(for: request, purpose: .extract, model: model)
      var evidence: [String] = []
      for (index, chunk) in chunks.enumerated() {
        try Task.checkCancellation()
        progress(IntelligenceProgress(phase: .reading, current: index + 1, total: chunks.count))
        let excerpts = try await backend.excerpts(
          for: pass(request, purpose: .extract, source: chunk.source, model: model))
        logger.notice(
          "request=\(request.id.uuidString, privacy: .public) action=ask chunk=\(index + 1)/\(chunks.count) range=\(chunk.range.location):\(chunk.range.length) excerpts=\(excerpts.count)"
        )
        for excerpt in excerpts {
          guard !Anchors.matches(excerpt, in: chunk.source).isEmpty else {
            throw IntelligenceError.unverifiedQuotation
          }
        }
        evidence.append(contentsOf: excerpts)
      }
      evidence = unique(evidence)
      logger.notice(
        "request=\(request.id.uuidString, privacy: .public) action=ask selectedExcerpts=\(evidence.count)"
      )
      guard !evidence.isEmpty else { throw IntelligenceError.noEvidence }
      input = try await combine(evidence, request: request, model: model, progress: progress)
    }
    progress(IntelligenceProgress(phase: .answering, current: 1, total: 1))
    var generated: [ModelAnswerPart] = []
    for attempt in 1...2 {
      try Task.checkCancellation()
      onPartialAnswer("")
      do {
        generated = try await backend.streamAnswer(for: input, onUpdate: onPartialAnswer)
      } catch IntelligenceError.responseTooLarge where attempt == 1 {
        logger.notice(
          "request=\(request.id.uuidString, privacy: .public) answerRejected=responseTooLarge attempt=1"
        )
        continue
      } catch IntelligenceError.unverifiedQuotation where attempt == 1 {
        logger.notice(
          "request=\(request.id.uuidString, privacy: .public) answerRejected=unverifiedQuotation attempt=1"
        )
        continue
      }
      let prose = generated.filter { $0.kind == .prose }.map(\.text).joined(separator: "\n\n")
      guard
        let issue = AnswerIssue.check(
          prose, source: input.source, instruction: input.instruction)
      else { break }
      logger.notice(
        "request=\(request.id.uuidString, privacy: .public) answerRejected=\(issue.rawValue, privacy: .public) attempt=\(attempt)"
      )
      if attempt == 2 { throw IntelligenceError.invalidAnswer(issue) }
    }
    try Task.checkCancellation()
    let visible = generated.filter {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !visible.isEmpty else { throw IntelligenceError.emptyAnswer }
    let parts = try visible.map { part -> Answer.Part in
      switch part.kind {
      case .prose: return .prose(part.text)
      case .quote:
        let bodyStart = Syntax.contentStart(in: request.snapshot.source)
        let ranges = Anchors.matches(part.text, in: request.snapshot.source).filter {
          $0.location >= bodyStart
        }
        guard !ranges.isEmpty else { throw IntelligenceError.unverifiedQuotation }
        return .quotation(Citation(quote: part.text, ranges: ranges))
      }
    }
    return Answer(parts: parts)
  }

  private func combine(
    _ initial: [String], request: IntelligenceRequest, model: ModelInfo,
    progress: @MainActor (IntelligenceProgress) -> Void
  ) async throws -> ModelPass {
    var evidence = initial
    for _ in 0..<8 {
      let source = evidence.joined(separator: "\n\n")
      let answer = pass(
        request, purpose: .answer, source: source, model: model, evidenceBlocks: evidence)
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
          let snapshot = FileSnapshot(
            fileID: request.snapshot.fileID, sessionID: request.snapshot.sessionID,
            generation: request.snapshot.generation, source: excerpt)
          let extraction = IntelligenceRequest(
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
          IntelligenceProgress(phase: .combining, current: index + 1, total: batches.count))
        let excerpts = try await backend.excerpts(
          for: pass(
            request, purpose: .extract, source: batch.joined(separator: "\n\n"), model: model,
            evidenceBlocks: batch))
        for excerpt in excerpts {
          guard evidence.contains(where: { !Anchors.matches(excerpt, in: $0).isEmpty }) else {
            throw IntelligenceError.unverifiedQuotation
          }
        }
        reduced.append(contentsOf: excerpts)
      }
      reduced = unique(reduced)
      guard !reduced.isEmpty else { throw IntelligenceError.noEvidence }
      guard reduced.reduce(0, { $0 + $1.utf8.count }) < evidence.reduce(0, { $0 + $1.utf8.count })
      else {
        throw IntelligenceError.insufficientContext
      }
      evidence = reduced
    }
    throw IntelligenceError.insufficientContext
  }

  private struct Chunk {
    let source: String
    let range: NSRange
  }

  private func content(in request: IntelligenceRequest) -> Chunk {
    let source = request.snapshot.source as NSString
    let start = Syntax.contentStart(in: request.snapshot.source)
    return Chunk(
      source: source.substring(from: start),
      range: NSRange(location: start, length: source.length - start))
  }

  private func chunks(
    for request: IntelligenceRequest, purpose: ModelPass.Purpose, model: ModelInfo
  ) async throws -> [Chunk] {
    try await split(content(in: request), request: request, purpose: purpose, model: model)
  }

  private func split(
    _ chunk: Chunk, request: IntelligenceRequest, purpose: ModelPass.Purpose,
    model: ModelInfo, force: Bool = false
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
    guard chunk.source.count > 1 else { throw IntelligenceError.insufficientContext }
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
      throw IntelligenceError.insufficientContext
    }
    let leftRange = NSRange(location: chunk.range.location, length: offset)
    let rightRange = NSRange(
      location: chunk.range.location + offset, length: chunk.range.length - offset)
    guard let left = Range(leftRange, in: request.snapshot.source),
      let right = Range(rightRange, in: request.snapshot.source)
    else { throw IntelligenceError.invalidResponse }
    let first = try await split(
      Chunk(source: String(request.snapshot.source[left]), range: leftRange),
      request: request, purpose: purpose, model: model)
    let second = try await split(
      Chunk(source: String(request.snapshot.source[right]), range: rightRange),
      request: request, purpose: purpose, model: model)
    return first + second
  }

  private func fits(_ pass: ModelPass, model: ModelInfo) async throws -> Bool {
    guard model.contextSize > 0, pass.responseTokens > 0 else {
      throw IntelligenceError.insufficientContext
    }
    let count = try await backend.tokenCount(for: pass)
    guard count >= 0 else { throw IntelligenceError.invalidResponse }
    let fits = count <= model.contextSize - pass.responseTokens - framingReserve
    logger.notice(
      "request=\(pass.requestID.uuidString, privacy: .public) phase=\(pass.purpose.rawValue, privacy: .public) inputTokens=\(count) responseTokens=\(pass.responseTokens) context=\(model.contextSize) fits=\(fits)"
    )
    return fits
  }

  private func pass(
    _ request: IntelligenceRequest, purpose: ModelPass.Purpose,
    source: String, model: ModelInfo, scope: NSRange? = nil,
    evidenceBlocks: [String]? = nil
  ) -> ModelPass {
    let bodyLength =
      request.snapshot.source.utf16.count - Syntax.contentStart(in: request.snapshot.source)
    return ModelPass(
      purpose: purpose, instruction: request.instruction, source: source,
      responseTokens: min(purpose == .answer ? answerTokens : 1_536, model.contextSize / 3),
      requestID: request.id,
      tasks: purpose == .edit
        ? request.snapshot.tasks.filter { task in
          guard let scope else { return true }
          return task.range.location >= scope.location
            && NSMaxRange(task.range) <= NSMaxRange(scope)
        } : [], evidenceBlocks: evidenceBlocks,
      isPart: scope.map { $0.length < bodyLength } ?? false)
  }

  private func validate(_ request: IntelligenceRequest) throws {
    if request.action != .review
      && request.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw IntelligenceError.emptyInstruction
    }
  }

  private func unique(_ strings: [String]) -> [String] {
    var seen = Set<Data>()
    return strings.filter { seen.insert(Data($0.utf8)).inserted }
  }
}
