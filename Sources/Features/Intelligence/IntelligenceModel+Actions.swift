import Foundation
import Markdown
import OSLog

let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "Intelligence")

extension IntelligenceModel {
    package func edit(
        _ request: IntelligenceRequest,
        progress: @MainActor (IntelligenceRequest.Progress) -> Void = { _ in }
    ) async throws -> Proposal {
        try await generate(request, purpose: .edit, progress: progress)
    }

    package func review(
        _ request: IntelligenceRequest,
        progress: @MainActor (IntelligenceRequest.Progress) -> Void = { _ in }
    ) async throws -> Proposal {
        try await generate(request, purpose: .review, progress: progress)
    }

    /// Review starts chunked; Edit starts with the whole body and splits only on context failure.
    private func generate(
        _ request: IntelligenceRequest, purpose: ModelPass.Purpose,
        progress: @MainActor (IntelligenceRequest.Progress) -> Void
    ) async throws -> Proposal {
        try Task.checkCancellation()
        if let unavailableReason { throw IntelligenceError.unavailable(unavailableReason) }
        let chunks =
            purpose == .edit
            ? [body(of: request)]
            : try await split(body(of: request), request: request, purpose: purpose)
        var candidates: [(Proposal.Change, NSRange)] = []
        var pending = Array(chunks.reversed())
        var completed = 0
        while let chunk = pending.popLast() {
            try Task.checkCancellation()
            let (current, total) = (completed + 1, completed + pending.count + 1)
            progress(purpose == .edit ? .editing(current, of: total) : .reviewing(current, of: total))
            do {
                let input = pass(request, purpose: purpose, source: text(chunk, of: request), scope: chunk)
                if purpose == .edit {
                    let operations = try await self.operations(for: input)
                    try Task.checkCancellation()
                    candidates += try operations.flatMap {
                        try $0.changes(in: request.document, pass: input, scope: chunk)
                    }
                } else {
                    let suggestions = try await self.suggestions(for: input)
                    try Task.checkCancellation()
                    candidates += suggestions.map { ($0, chunk) }
                }
                completed += 1
                // Selection needs a smaller part when the response or context cannot fit.
            } catch IntelligenceError.responseTooLarge where purpose == .review,
                IntelligenceError.insufficientContext
            {
                let smaller = try await split(
                    chunk, request: request, purpose: purpose, force: true)
                pending.append(contentsOf: smaller.reversed())
            }
        }
        let proposal = Proposal(
            document: request.document, scopedCandidates: candidates,
            safetyInstruction: request.instruction)
        if proposal.canApply {
            _ = try proposal.application()
        }
        return proposal
    }

    package func ask(
        _ request: IntelligenceRequest,
        progress: @MainActor (IntelligenceRequest.Progress) -> Void = { _ in },
        onPartialAnswer: @MainActor (String) -> Void = { _ in }
    ) async throws -> Answer {
        try Task.checkCancellation()
        if let unavailableReason { throw IntelligenceError.unavailable(unavailableReason) }
        logger.notice(
            "request=\(request.id.uuidString, privacy: .public) action=ask context=\(contextSize)"
        )
        let body = body(of: request)
        let whole = pass(request, purpose: .answer, source: text(body, of: request))
        let input: ModelPass
        let wholeFits = try await fits(whole)
        logger.notice(
            "request=\(request.id.uuidString, privacy: .public) action=ask path=\(wholeFits ? "whole" : "extract", privacy: .public) bodyUTF16=\(body.length) frontMatterUTF16=\(body.location)"
        )
        if wholeFits {
            input = whole
        } else {
            let chunks = try await split(body, request: request, purpose: .extract)
            var evidence: [String] = []
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                progress(.reading(index + 1, of: chunks.count))
                let source = text(chunk, of: request)
                let excerpts = try await self.excerpts(
                    for: pass(request, purpose: .extract, source: source))
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
            input = try await combine(evidence, request: request, progress: progress)
        }
        progress(.answering)
        var reply = Answer.Reply(prose: "")
        for attempt in 1...2 {
            try Task.checkCancellation()
            onPartialAnswer("")
            do {
                reply = try await self.reply(to: input, onUpdate: onPartialAnswer)
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
            guard let issue = reply.issue(answering: input.instruction, in: input.source) else { break }
            logger.notice(
                "request=\(request.id.uuidString, privacy: .public) answerRejected=\(issue.rawValue, privacy: .public) attempt=\(attempt)"
            )
            if attempt == 2 { throw IntelligenceError.invalidAnswer(issue) }
        }
        try Task.checkCancellation()
        return try Answer(reply, in: request.document)
    }

    private func combine(
        _ initial: [String], request: IntelligenceRequest,
        progress: @MainActor (IntelligenceRequest.Progress) -> Void
    ) async throws -> ModelPass {
        var evidence = initial
        for _ in 0..<8 {
            let source = evidence.joined(separator: "\n\n")
            let answer = pass(
                request, purpose: .answer, source: source, evidenceBlocks: evidence)
            if try await fits(answer) { return answer }
            var batches: [[String]] = []
            var batch: [String] = []
            for excerpt in evidence {
                let proposed = batch + [excerpt]
                let probe = pass(
                    request, purpose: .extract, source: proposed.joined(separator: "\n\n"),
                    evidenceBlocks: proposed)
                if try await fits(probe) {
                    batch = proposed
                } else {
                    if !batch.isEmpty { batches.append(batch) }
                    batch = []
                    let extraction = IntelligenceRequest(
                        document: MarkdownDocument(excerpt), instruction: request.instruction, id: request.id)
                    let parts = try await split(
                        body(of: extraction), request: extraction, purpose: .extract)
                    batches.append(contentsOf: parts.map { [text($0, of: extraction)] })
                }
            }
            if !batch.isEmpty { batches.append(batch) }
            var reduced: [String] = []
            for (index, batch) in batches.enumerated() {
                try Task.checkCancellation()
                progress(.combining(index + 1, of: batches.count))
                let excerpts = try await self.excerpts(
                    for: pass(
                        request, purpose: .extract, source: batch.joined(separator: "\n\n"),
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
        let document = request.document
        return NSRange(document.contentStart..<NSMaxRange(document.range))
    }

    private func text(_ range: NSRange, of request: IntelligenceRequest) -> String {
        request.document.text(in: range)
    }

    private func split(
        _ chunk: NSRange, request: IntelligenceRequest, purpose: ModelPass.Purpose,
        force: Bool = false
    ) async throws -> [NSRange] {
        try Task.checkCancellation()
        let source = text(chunk, of: request)
        if !force,
            try await fits(
                pass(request, purpose: purpose, source: source, scope: chunk))
        {
            return [chunk]
        }
        guard source.count > 1 else { throw IntelligenceError.insufficientContext }
        let midpoint = chunk.location + chunk.length / 2
        let headings = request.document.blocks(in: chunk).filter { $0.kind == .heading }
            .map(\.range.location).filter { $0 > chunk.location && $0 < NSMaxRange(chunk) }
        let heading = headings.min { abs($0 - midpoint) < abs($1 - midpoint) }
        let offset: Int
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
        guard offset > 0, offset < chunk.length else {
            throw IntelligenceError.insufficientContext
        }
        let left = NSRange(location: chunk.location, length: offset)
        let right = NSRange(location: NSMaxRange(left), length: chunk.length - offset)
        let first = try await split(left, request: request, purpose: purpose)
        let second = try await split(right, request: request, purpose: purpose)
        return first + second
    }

    private func fits(_ pass: ModelPass) async throws -> Bool {
        let count = try await tokenCount(for: pass)
        let fits = count <= contextSize - pass.responseTokens
        logger.notice(
            "request=\(pass.requestID.uuidString, privacy: .public) phase=\(pass.purpose.rawValue, privacy: .public) inputTokens=\(count) responseTokens=\(pass.responseTokens) context=\(contextSize) fits=\(fits)"
        )
        return fits
    }

    private func pass(
        _ request: IntelligenceRequest, purpose: ModelPass.Purpose,
        source: String, scope: NSRange? = nil,
        evidenceBlocks: [String]? = nil
    ) -> ModelPass {
        let bodyLength = request.document.range.length - request.document.contentStart
        return ModelPass(
            purpose: purpose, instruction: request.instruction, source: source,
            responseTokens: min(purpose == .answer ? ModelPass.answerTokens : 1_536, contextSize / 3),
            requestID: request.id, evidenceBlocks: evidenceBlocks,
            isPart: scope.map { $0.length < bodyLength } ?? false)
    }

    private func unique(_ strings: [String]) -> [String] {
        var seen = Set<Data>()
        return strings.filter { seen.insert(Data($0.utf8)).inserted }
    }
}
