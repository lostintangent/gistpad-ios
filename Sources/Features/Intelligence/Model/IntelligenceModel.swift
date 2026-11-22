import Foundation

@MainActor
package protocol IntelligenceModel {
  func modelInfo() async throws -> ModelInfo
  func tokenCount(for pass: ModelPass) async throws -> Int
  /// Edit's operations, or Review's suggestions as replacements.
  func editOperations(for pass: ModelPass) async throws -> [ModelEdit]
  func excerpts(for pass: ModelPass) async throws -> [String]
  func streamAnswer(
    for pass: ModelPass, onUpdate: @MainActor (String) -> Void
  ) async throws -> ModelAnswer
}

package struct ModelInfo: Sendable {
  package let variant: String
  package let contextSize: Int
}

package struct ModelPass: Sendable {
  enum Purpose: String, Sendable { case answer, extract, edit, review }
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

package enum ModelEdit: Sendable {
  case replace(Proposal.Change)
  case setTaskStates(ids: [Int]?, isComplete: Bool)
  case insertTask(listID: Int, text: String)
  case deleteTasks(ids: [Int])
  /// A region as the model revised it, using a UTF-16 range relative to the model pass.
  /// The app compares it line by line.
  case rewriteRegion(NSRange, revised: String)
  case replaceRegion(NSRange, Proposal.Change)
}

package struct ModelAnswer: Sendable, Equatable {
  package var prose: String
  var quotes: [String] = []
}
