import Foundation

package protocol IntelligenceModel {
    /// Why the model can't run right now, or nil when it can. Views that read it stay current.
    var unavailableReason: String? { get }
    /// The tokens one session holds, its instructions, prompt and response together.
    var contextSize: Int { get }
    func tokenCount(for pass: ModelPass) async throws -> Int
    func operations(for pass: ModelPass) async throws -> [EditOperation]
    func suggestions(for pass: ModelPass) async throws -> [Proposal.Change]
    func excerpts(for pass: ModelPass) async throws -> [String]
    /// Ask's reply, streaming its visible prose to `onUpdate`.
    func reply(
        to pass: ModelPass, onUpdate: @MainActor (String) -> Void
    ) async throws -> Answer.Reply
}

package struct ModelPass: Sendable {
    enum Purpose: String { case answer, extract, edit, review }
    // Platform gap: GenerationOptions has no repetition penalty or stop sequence, so a runaway answer
    // runs to this limit and is retried once. Remove the retry and raise the limit when it has one.
    /// Real answers use under 120 tokens.
    static let answerTokens = 384
    let purpose: Purpose
    package let instruction: String
    package let source: String
    let responseTokens: Int
    var requestID = UUID()
    var tasks: [ModelTask] = []
    var evidenceBlocks: [String]?
    /// Whether the source is one part of a note too long for one pass.
    var isPart = false
}

/// A task as the note has it. It encodes for the model without its range.
package struct ModelTask: Sendable, Encodable {
    let id: Int
    package let range: NSRange
    package let text: String
    package let isComplete: Bool
    var listID = 1
    package var listTitle = ""

    private enum CodingKeys: CodingKey { case id, text, isComplete, listID, listTitle }

    static func indexed(
        in source: String, markers: [NSRange], headings: [NSRange]
    ) -> [ModelTask] {
        let text = source as NSString
        var previousEnd: Int?
        var listID = 0
        return markers.sorted { $0.location < $1.location }.enumerated().map { index, marker in
            let line = text.lineRange(for: marker)
            if previousEnd != line.location { listID += 1 }
            previousEnd = NSMaxRange(line)
            let heading = headings.last { NSMaxRange($0) <= line.location }
            return ModelTask(
                id: index + 1, range: marker,
                text: text.substring(with: line).trimmingCharacters(in: .newlines),
                isComplete: text.substring(with: marker) != "[ ]",
                listID: listID, listTitle: heading.map { text.substring(with: $0) } ?? "")
        }
    }
}
