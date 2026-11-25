import Foundation
import FoundationModels
import OSLog

package final class OnDeviceModel: IntelligenceModel {
    let model = SystemLanguageModel.default

    package init() {}

    package var unavailableReason: String? {
        switch model.availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            String(localized: "This device doesn’t support Apple Intelligence.", bundle: .module)
        case .unavailable(.appleIntelligenceNotEnabled):
            String(
                localized: "Turn on Apple Intelligence in Settings to use these actions.", bundle: .module)
        case .unavailable(.modelNotReady):
            String(
                localized: "The on-device model isn’t ready yet. Let its download finish, then try again.",
                bundle: .module)
        case .unavailable:
            String(localized: "Apple Intelligence is currently unavailable.", bundle: .module)
        }
    }

    package var contextSize: Int { model.contextSize }

    /// The model's name, for the eval's report.
    package var variant: String { model.variant.displayName }

    /// Everything a session reads before it responds, as its usage reports it.
    package func tokenCount(for pass: ModelPass) async throws -> Int {
        let instructions = Transcript.Segment.text(.init(content: Self.instructions(for: pass)))
        let prompt = Transcript.Segment.text(.init(content: try Self.prompt(for: pass)))
        let format = try Self.schema(for: pass).map(Transcript.ResponseFormat.init(schema:))
        return try await model.tokenCount(for: [
            .instructions(.init(segments: [instructions], toolDefinitions: [])),
            .prompt(.init(segments: [prompt], responseFormat: format)),
        ])
    }

    func perform<Value>(
        pass: ModelPass,
        _ operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        let started = ContinuousClock.now
        logger.notice(
            "request=\(pass.requestID.uuidString, privacy: .public) generation=start phase=\(pass.purpose.rawValue, privacy: .public) sourceUTF16=\(pass.source.utf16.count)"
        )
        defer {
            logger.notice(
                "request=\(pass.requestID.uuidString, privacy: .public) generation=end elapsedMs=\(Int(started.duration(to: .now) / .milliseconds(1)))"
            )
        }
        do {
            return try await operation()
        } catch let error as LanguageModelError {
            logger.error(
                "request=\(pass.requestID.uuidString, privacy: .public) modelFailure=\(Self.errorCode(error), privacy: .public)"
            )
            switch error {
            case .contextSizeExceeded:
                throw IntelligenceError.insufficientContext
            case .refusal, .guardrailViolation:
                throw IntelligenceError.refused
            case .rateLimited:
                throw IntelligenceError.rateLimited
            case .timeout:
                throw IntelligenceError.timedOut
            case .unsupportedLanguageOrLocale:
                throw IntelligenceError.unavailable(
                    String(
                        localized: "Apple Intelligence doesn’t support this language or region yet.",
                        bundle: .module))
            default:
                throw error
            }
        }
    }

    private static func errorCode(_ error: LanguageModelError) -> String {
        switch error {
        case .contextSizeExceeded: "contextSizeExceeded"
        case .rateLimited: "rateLimited"
        case .guardrailViolation: "guardrailViolation"
        case .refusal: "refusal"
        case .unsupportedCapability: "unsupportedCapability"
        case .unsupportedTranscriptContent: "unsupportedTranscriptContent"
        case .unsupportedGenerationGuide: "unsupportedGenerationGuide"
        case .unsupportedLanguageOrLocale: "unsupportedLanguageOrLocale"
        case .timeout: "timeout"
        @unknown default: "unknown"
        }
    }

    func session(for pass: ModelPass) -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: Instructions(Self.instructions(for: pass)))
    }

    private struct Payload: Encodable {
        let request: String
        let blocks: [SourceBlock]
    }

    static func blocks(for pass: ModelPass) -> [SourceBlock] {
        pass.evidenceBlocks?.enumerated().map { SourceBlock(id: $0.offset + 1, text: $0.element) }
            ?? SourceBlock.blocks(in: pass.source)
    }

    /// Prompt JSON, with sorted keys so the same pass always reads the same.
    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func prompt(for pass: ModelPass) throws -> String {
        if pass.purpose == .edit, pass.isPart {
            let delimiter = delimiter(for: pass.source)
            return "Request:\n\(pass.instruction)\n\nNote:\n\(delimiter)\n\(pass.source)\n\(delimiter)"
        }
        if pass.purpose == .edit {
            return try json(["note": pass.source, "request": pass.instruction])
        }
        return try json(Payload(request: pass.instruction, blocks: blocks(for: pass)))
    }


    /// A backtick fence longer than any inside the text.
    static func delimiter(for text: String) -> String {
        var run = 0
        var longest = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    static func schema(for pass: ModelPass) throws -> GenerationSchema? {
        switch pass.purpose {
        case .answer: return nil
        case .extract:
            let count = blocks(for: pass).count
            guard count > 0 else { throw IntelligenceError.noEvidence }
            return try idSchema(
                named: "BlockSelection", description: "IDs of relevant blocks. Empty if none are relevant.",
                count: count, maximum: 4)
        case .edit: return nil
        }
    }

    /// Up to `maximum` block IDs from 1 through `count`, a range only known at runtime.
    static func idSchema(
        named name: String, description: String, count: Int, maximum: Int
    ) throws -> GenerationSchema {
        let root = DynamicGenerationSchema(
            name: name,
            properties: [
                .init(
                    name: "blockIDs", description: description,
                    schema: DynamicGenerationSchema(
                        arrayOf: DynamicGenerationSchema(type: Int.self, guides: [.range(1...count)]),
                        maximumElements: maximum))
            ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func instructions(for pass: ModelPass) -> String {
        switch pass.purpose {
        case .answer: answerInstructions(for: pass)
        case .extract: extractInstructions(for: pass)
        case .edit: editInstructions(for: pass)
        }
    }
}
