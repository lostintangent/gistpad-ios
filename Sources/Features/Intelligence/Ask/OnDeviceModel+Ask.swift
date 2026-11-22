import Foundation
import FoundationModels
import OSLog

extension OnDeviceModel {
  package func excerpts(for pass: ModelPass) async throws -> [String] {
    try await perform(pass: pass) {
      let blocks = Self.blocks(for: pass)
      guard let schema = try Self.schema(for: pass) else {
        throw IntelligenceError.noEvidence
      }
      let session = session(for: pass)
      let response = try await session.respond(
        to: Self.prompt(for: pass), schema: schema,
        options: GenerationOptions(temperature: 0.1, maximumResponseTokens: pass.responseTokens))
      let ids: [Int] = try response.content.value(forProperty: "blockIDs")
      logger.notice(
        "request=\(pass.requestID.uuidString, privacy: .public) phase=extract availableBlockCount=\(blocks.count) selectedBlockIDs=\(ids.map(String.init).joined(separator: ","), privacy: .public)"
      )
      return try SourceBlock.quotations(ids: ids, from: blocks)
    }
  }

  package func streamAnswer(
    for pass: ModelPass, onUpdate: @MainActor (String) -> Void
  ) async throws -> ModelAnswer {
    try await perform(pass: pass) {
      let stream = session(for: pass).streamResponse(
        to: try Self.prompt(for: pass),
        options: GenerationOptions(temperature: 0.2, maximumResponseTokens: pass.responseTokens))
      var latest = ""
      for try await snapshot in stream {
        try Task.checkCancellation()
        latest = snapshot.content
        guard snapshot.usage.output.totalTokenCount < pass.responseTokens else {
          throw IntelligenceError.responseTooLarge
        }
        onUpdate(Self.visibleAnswer(latest))
      }
      return try Self.parseAnswer(latest, blocks: Self.blocks(for: pass))
    }
  }

  static func parseAnswer(_ content: String, blocks: [SourceBlock]) throws -> ModelAnswer {
    let response = content.trimmingCharacters(in: .whitespacesAndNewlines)
    let marker = /(?i)(?:\n|[ \t]+)\[?sources:\s*([0-9]+(?:\s*,\s*[0-9]+)*)\]?\s*$/
    let match = response.firstMatch(of: marker)
    let prose = (match.map { String(response[..<$0.range.lowerBound]) } ?? response)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prose.isEmpty else {
      throw IntelligenceError.emptyAnswer
    }
    if match == nil, response.range(of: #"(?i)(?:^|\s)\[?sources\s*:"#,
      options: .regularExpression) != nil
    {
      throw IntelligenceError.invalidResponse
    }
    if let match {
      let suffix = response[match.range]
      guard suffix.contains("[") == suffix.contains("]") else {
        throw IntelligenceError.invalidResponse
      }
    }
    let ids: [Int]
    if let match {
      ids = String(match.output.1).split(separator: ",").compactMap {
        Int($0.trimmingCharacters(in: .whitespaces))
      }
      guard (1...3).contains(ids.count) else { throw IntelligenceError.unverifiedQuotation }
    } else {
      ids = []
    }
    return ModelAnswer(prose: prose, quotes: try SourceBlock.quotations(ids: ids, from: blocks))
  }

  static func visibleAnswer(_ content: String) -> String {
    if let marker = content.range(
      of: #"(?i)(?:\n|[ \t]+)\[?sources:"#,
      options: .regularExpression)
    {
      return String(content[..<marker.lowerBound])
    }
    if let separator = content.lastIndex(where: { $0 == "\n" || $0 == " " || $0 == "\t" }) {
      let tail = content[content.index(after: separator)...].lowercased()
      if !tail.isEmpty, (1..<8).contains(tail.count),
        "[sources:".hasPrefix(tail) || "sources:".hasPrefix(tail)
      {
        return String(content[..<separator])
      }
    }
    return content
  }

  static func answerInstructions(for pass: ModelPass) -> String {
    let question = pass.instruction.lowercased()
    let evidence =
      pass.evidenceBlocks != nil
      ? """

      These are selected verbatim passages from a longer note, not its complete text.
      Do not claim exhaustive counts or conclusions requiring missing context.
      Explain when the available evidence cannot safely answer the request.
      """
      : ""
    let preference = asksForFavorite(question)
      ? """

      For a favorite or top choice, use an explicit preference if stated.
      Otherwise #1 in the highest-rated completed section is the best-supported
      inference, not an explicit claim. Start the answer
      "Your likely favorite is" followed immediately by that series' exact
      title, then say this follows from your ranking. Do not first describe
      the tier or your attention.
      Read the literal item marked "1." in that tier, never item "2.".
      Reading order and volume counts do not measure preference.
      """
      : ""
    let summary =
      question.contains("summary") || question.contains("summarize")
      ? """

      Summarize the actual headings and lists, including ongoing, paused and
      completed/ranked categories when present. Do not substitute themes for
      the note's organization.
      """
      : ""
    return commonInstructions + evidence + """

      Answer the specific question in the first sentence, in plain prose, not JSON.
      Use one to three sentences and at most 60 words. Paraphrase without quotation
      marks; the app adds exact quotes.
      Never expose IDs, field names, metadata, HTML or implementation details.
      Answer only the question asked, not another question about the note.
      If the evidence cannot answer, explain the limit instead of guessing.
      Finish with [Sources: 1, 2] on its own line, using up to three supporting
      block IDs. Omit it if none support the answer. Never put IDs in prose.
      """ + preference + "\nAddress the reader as you/your." + summary
  }

  static func extractInstructions(for pass: ModelPass) -> String {
    let preference = asksForFavorite(pass.instruction)
      ? """

      For a favorite or top choice, select an explicit favorite statement or the
      highest-rated completed tier and its first-ranked item. Include its completed
      heading if present. Ignore reading order, stopped lists and lower-rated tiers.
      If this part has neither, return an empty blockIDs array.
      """
      : ""
    return commonInstructions + """

      Select only blocks needed to answer the request; keep relevant headings.
      IDs restart at 1 in each part; list item numbers are not block IDs.
      Return an empty blockIDs array if nothing in this part answers the request.
      """ + preference
  }

  private static func asksForFavorite(_ question: String) -> Bool {
    let lower = question.lowercased()
    return [
      "favorite", "favourite", "top choice", "top manga", "like most",
      "enjoy most", "prefer most",
    ].contains { lower.contains($0) }
  }
}
