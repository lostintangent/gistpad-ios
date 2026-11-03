import Foundation

public enum AnswerIssue: String, Sendable {
  case unverifiedProseQuote
  case internalIdentifier
  case thirdPerson
  case markupLeak

  static func check(_ answer: String, source: String, instruction: String = "") -> Self? {
    func isSupportedQuote(_ quote: String) -> Bool {
      guard quote.first?.isLetter == true, quote.last?.isLetter == true else {
        return !Anchors.matches(quote, in: source).isEmpty
      }
      let pattern = #"(?<![\p{L}\p{N}])"#
        + NSRegularExpression.escapedPattern(for: quote)
        + #"(?![\p{L}\p{N}])"#
      return source.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    for match in answer.matches(of: /["“]([^"”\n]+)["”]/) {
      if !isSupportedQuote(String(match.output.1)) {
        return .unverifiedProseQuote
      }
    }
    for match in answer.matches(of: /(?:^|[\s(\[])['‘]([^\n]+?)['’](?=$|[\s).,!?:;\]])/) {
      if !isSupportedQuote(String(match.output.1)) {
        return .unverifiedProseQuote
      }
    }
    for match in answer.matches(of: /[「『«]([^」』»\n]+)[」』»]/) {
      if !isSupportedQuote(String(match.output.1)) {
        return .unverifiedProseQuote
      }
    }
    func isAuthored(_ text: String) -> Bool {
      source.localizedCaseInsensitiveContains(text)
        || instruction.localizedCaseInsensitiveContains(text)
    }
    for match in answer.matches(
      of:
        /(?i)\b(?:blockIDs?|firstOrderedItem|evidenceBlocks|sourceUTF16|requestID|listID|taskIDs?|(?:source|evidence) blocks?|block\s*#?\s*(?:\d+|one|two|three|four)|(?:first|second|third) block)\b/
    ) {
      if !isAuthored(String(match.output)) {
        return .internalIdentifier
      }
    }
    for match in answer.matches(of: /(?i)\bthe (?:user|creator)\b/) {
      if !isAuthored(String(match.output)) {
        return .thirdPerson
      }
    }
    for match in answer.matches(of: /(?i)<\/?[a-z][a-z0-9-]*(?:\s+[^>]*)?>|[{}]/) {
      if !source.contains(String(match.output)) { return .markupLeak }
    }
    return nil
  }
}
