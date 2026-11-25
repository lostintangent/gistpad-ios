import Foundation
import Markdown
import OSLog

let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "Intelligence")

package final class IntelligenceEngine {
    let backend: any IntelligenceModel
    // Platform gap: GenerationOptions has no repetition penalty or stop sequence, so a runaway answer
    // runs to this limit and is retried once. Remove the retry and raise the limit when it has one.
    /// Real answers use under 120 tokens.
    private let answerTokens = 384

    /// Where a long request is, for the sheet's progress label.
    package enum Progress: Sendable {
        case reading(Int, of: Int)
        case editing(Int, of: Int)
        case reviewing(Int, of: Int)
        case combining(Int, of: Int)
        case answering
    }

    package init(backend: any IntelligenceModel) {
        self.backend = backend
    }

    package func edit(
        _ request: IntelligenceRequest,
        progress: @MainActor (Progress) -> Void = { _ in }
    ) async throws -> Proposal {
        try await generate(request, purpose: .edit, progress: progress)
    }

    package func review(
        _ request: IntelligenceRequest,
        progress: @MainActor (Progress) -> Void = { _ in }
    ) async throws -> Proposal {
        try await generate(request, purpose: .review, progress: progress)
    }

    /// Review starts chunked; Edit starts with the whole body and splits only on context failure.
    private func generate(
        _ request: IntelligenceRequest, purpose: ModelPass.Purpose,
        progress: @MainActor (Progress) -> Void
    ) async throws -> Proposal {
        try Task.checkCancellation()
        let model = try await backend.modelInfo()
        let chunks =
            purpose == .edit
            ? [body(of: request)]
            : try await split(body(of: request), request: request, purpose: purpose, model: model)
        var candidates: [(Proposal.Change, NSRange)] = []
        var pending = Array(chunks.reversed())
        var completed = 0
        while let chunk = pending.popLast() {
            try Task.checkCancellation()
            let (current, total) = (completed + 1, completed + pending.count + 1)
            progress(purpose == .edit ? .editing(current, of: total) : .reviewing(current, of: total))
            let chunkSource = text(chunk, of: request)
            do {
                let input = pass(request, purpose: purpose, source: chunkSource, model: model, scope: chunk)
                let operations = try await backend.editOperations(for: input)
                try Task.checkCancellation()
                for operation in operations {
                    switch operation {
                    case .replace(let candidate):
                        if purpose == .edit, candidate.replacement == nil {
                            throw IntelligenceError.invalidResponse
                        }
                        candidates.append((candidate, chunk))
                    case .setTaskStates(let ids, let isComplete):
                        guard ids.map({ !$0.isEmpty && Set($0).count == $0.count }) ?? true
                        else { throw IntelligenceError.invalidResponse }
                        let selected =
                            ids.map { identifiers in
                                input.tasks.filter { identifiers.contains($0.id) }
                            } ?? input.tasks
                        guard ids == nil || selected.count == ids?.count else {
                            throw IntelligenceError.invalidResponse
                        }
                        for task in selected where task.isComplete != isComplete {
                            candidates.append(
                                (
                                    Proposal.Change(
                                        quote: (request.snapshot.source as NSString).substring(with: task.range),
                                        replacement: isComplete ? "[x]" : "[ ]",
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
                                    Proposal.Change(
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
                                Proposal.Change(
                                    quote: "", replacement: insertion,
                                    reason: String(localized: "Add this task.", bundle: .module)),
                                NSRange(location: offset, length: 0)
                            ))
                    case .rewriteRegion(let relative, let revised):
                        guard relative.location >= 0, NSMaxRange(relative) <= chunk.length
                        else { throw IntelligenceError.invalidResponse }
                        candidates += try Proposal.Change.lineChanges(
                            in: request.snapshot.source,
                            visible: NSRange(
                                location: chunk.location + relative.location, length: relative.length),
                            revised: revised)
                    case .replaceRegion(let relative, let candidate):
                        guard relative.location >= 0, relative.length > 0,
                            NSMaxRange(relative) <= chunk.length,
                            candidate.replacement != nil,
                            candidate.quote.utf8.elementsEqual(
                                (chunkSource as NSString).substring(with: relative).utf8)
                        else { throw IntelligenceError.invalidResponse }
                        candidates.append(
                            (
                                candidate,
                                NSRange(location: chunk.location + relative.location, length: relative.length)
                            ))
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
        let proposal = Proposal(
            snapshot: request.snapshot, scopedCandidates: candidates,
            safetyInstruction: request.instruction)
        if proposal.canApply {
            _ = try proposal.application(to: request.snapshot)
        }
        return proposal
    }

    package func ask(
        _ request: IntelligenceRequest,
        progress: @MainActor (Progress) -> Void = { _ in },
        onPartialAnswer: @MainActor (String) -> Void = { _ in }
    ) async throws -> [AnswerPart] {
        try Task.checkCancellation()
        let model = try await backend.modelInfo()
        logger.notice(
            "request=\(request.id.uuidString, privacy: .public) action=ask model=\(model.variant, privacy: .public) context=\(model.contextSize)"
        )
        let body = body(of: request)
        let whole = pass(request, purpose: .answer, source: text(body, of: request), model: model)
        let input: ModelPass
        let wholeFits = try await fits(whole, model: model)
        logger.notice(
            "request=\(request.id.uuidString, privacy: .public) action=ask path=\(wholeFits ? "whole" : "extract", privacy: .public) bodyUTF16=\(body.length) frontMatterUTF16=\(body.location)"
        )
        if wholeFits {
            input = whole
        } else {
            let chunks = try await split(body, request: request, purpose: .extract, model: model)
            var evidence: [String] = []
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                progress(.reading(index + 1, of: chunks.count))
                let source = text(chunk, of: request)
                let excerpts = try await backend.excerpts(
                    for: pass(request, purpose: .extract, source: source, model: model))
                logger.notice(
                    "request=\(request.id.uuidString, privacy: .public) action=ask chunk=\(index + 1)/\(chunks.count) range=\(chunk.location):\(chunk.length) excerpts=\(excerpts.count)"
                )
                for excerpt in excerpts {
                    guard !source.exactRanges(of: excerpt).isEmpty else {
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
        progress(.answering)
        var generated = ModelAnswer(prose: "")
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
            guard
                let issue = ModelAnswer.Issue.check(
                    generated.prose, source: input.source, instruction: input.instruction)
            else { break }
            logger.notice(
                "request=\(request.id.uuidString, privacy: .public) answerRejected=\(issue.rawValue, privacy: .public) attempt=\(attempt)"
            )
            if attempt == 2 { throw IntelligenceError.invalidAnswer(issue) }
        }
        try Task.checkCancellation()
        let prose: [AnswerPart] =
            generated.prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [] : [.prose(generated.prose)]
        guard !prose.isEmpty || !generated.quotes.isEmpty else { throw IntelligenceError.emptyAnswer }
        let bodyStart = MarkdownDocument(request.snapshot.source).contentStart
        return try prose
            + generated.quotes.map { quote in
                let ranges = request.snapshot.source.exactRanges(of: quote).filter {
                    $0.location >= bodyStart
                }
                guard !ranges.isEmpty else { throw IntelligenceError.unverifiedQuotation }
                return .quotation(quote, ranges: ranges)
            }
    }

    private func combine(
        _ initial: [String], request: IntelligenceRequest, model: ModelInfo,
        progress: @MainActor (Progress) -> Void
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
                        sessionID: request.snapshot.sessionID, generation: request.snapshot.generation,
                        source: excerpt)
                    let extraction = IntelligenceRequest(
                        snapshot: snapshot, instruction: request.instruction, id: request.id)
                    let parts = try await split(
                        body(of: extraction), request: extraction, purpose: .extract, model: model)
                    batches.append(contentsOf: parts.map { [text($0, of: extraction)] })
                }
            }
            if !batch.isEmpty { batches.append(batch) }
            var reduced: [String] = []
            for (index, batch) in batches.enumerated() {
                try Task.checkCancellation()
                progress(.combining(index + 1, of: batches.count))
                let excerpts = try await backend.excerpts(
                    for: pass(
                        request, purpose: .extract, source: batch.joined(separator: "\n\n"), model: model,
                        evidenceBlocks: batch))
                for excerpt in excerpts {
                    guard evidence.contains(where: { !$0.exactRanges(of: excerpt).isEmpty }) else {
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

    /// The note after its front matter.
    private func body(of request: IntelligenceRequest) -> NSRange {
        let start = MarkdownDocument(request.snapshot.source).contentStart
        return NSRange(location: start, length: request.snapshot.source.utf16.count - start)
    }

    private func text(_ range: NSRange, of request: IntelligenceRequest) -> String {
        (request.snapshot.source as NSString).substring(with: range)
    }

    private func split(
        _ chunk: NSRange, request: IntelligenceRequest, purpose: ModelPass.Purpose,
        model: ModelInfo, force: Bool = false
    ) async throws -> [NSRange] {
        try Task.checkCancellation()
        let source = text(chunk, of: request)
        if !force,
            try await fits(
                pass(request, purpose: purpose, source: source, model: model, scope: chunk), model: model)
        {
            return [chunk]
        }
        guard source.count > 1 else { throw IntelligenceError.insufficientContext }
        let midpoint = chunk.location + chunk.length / 2
        let headings = request.snapshot.headingOffsets.filter {
            $0 > chunk.location && $0 < NSMaxRange(chunk)
        }
        let heading = headings.min { abs($0 - midpoint) < abs($1 - midpoint) }
        var offset: Int
        if let heading {
            offset = heading - chunk.location
        } else {
            let indices = Array(source.indices)
            let middleOffset = indices.count / 2
            let middle = indices[middleOffset]
            let newline = indices.enumerated().filter { source[$0.element].isNewline }.min {
                abs($0.offset - middleOffset) < abs($1.offset - middleOffset)
            }
            let boundary = newline.map { source.index(after: $0.element) } ?? middle
            let safeBoundary = boundary == source.endIndex ? middle : boundary
            offset = source[..<safeBoundary].utf16.count
        }
        let boundary = chunk.location + offset
        if let task = request.snapshot.tasks.first(where: {
            $0.range.location < boundary && boundary < NSMaxRange($0.range)
        }) {
            offset =
                task.range.location > chunk.location
                ? task.range.location - chunk.location : NSMaxRange(task.range) - chunk.location
        }
        guard offset > 0, offset < chunk.length else {
            throw IntelligenceError.insufficientContext
        }
        let left = NSRange(location: chunk.location, length: offset)
        let right = NSRange(location: NSMaxRange(left), length: chunk.length - offset)
        let first = try await split(left, request: request, purpose: purpose, model: model)
        let second = try await split(right, request: request, purpose: purpose, model: model)
        return first + second
    }

    private func fits(_ pass: ModelPass, model: ModelInfo) async throws -> Bool {
        let count = try await backend.tokenCount(for: pass)
        let fits = count <= model.contextSize - pass.responseTokens
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
            request.snapshot.source.utf16.count - MarkdownDocument(request.snapshot.source).contentStart
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

    private func unique(_ strings: [String]) -> [String] {
        var seen = Set<Data>()
        return strings.filter { seen.insert(Data($0.utf8)).inserted }
    }
}
