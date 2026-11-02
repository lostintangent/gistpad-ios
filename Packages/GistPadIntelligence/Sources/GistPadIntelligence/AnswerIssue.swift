import Foundation

public enum AnswerIssue: String, Sendable {
  case unverifiedProseQuote
  case internalIdentifier
  case thirdPerson
  case markupLeak

  public static func check(_ answer: String, source: String, instruction: String = "") -> Self? {
    for match in answer.matches(of: /["“]([^"”\n]+)["”]/) {
      if Anchors.matches(String(match.output.1), in: source).isEmpty {
        return .unverifiedProseQuote
      }
    }
    for match in answer.matches(of: /(?:^|[\s(\[])['‘]([^\n]+?)['’](?=$|[\s).,!?:;\]])/) {
      if Anchors.matches(String(match.output.1), in: source).isEmpty {
        return .unverifiedProseQuote
      }
    }
    for match in answer.matches(of: /[「『«]([^」』»\n]+)[」』»]/) {
      if Anchors.matches(String(match.output.1), in: source).isEmpty {
        return .unverifiedProseQuote
      }
    }
    func isAuthored(_ text: String) -> Bool {
      source.localizedCaseInsensitiveContains(text)
        || instruction.localizedCaseInsensitiveContains(text)
    }
    for match in answer.matches(
      of:
        /(?i)\b(?:blockIDs?|firstOrderedItem|evidenceBlocks|sourceUTF16|requestID|listID|taskIDs?|ranking evidence|(?:source|evidence) blocks?|block\s*#?\s*(?:\d+|one|two|three|four)|(?:first|second|third) block)\b/
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
    for match in answer.matches(of: /(?i)<\/?(?:span|div|script|html|body)[^>]*>|[{}]/) {
      if !source.contains(String(match.output)) { return .markupLeak }
    }
    return nil
  }
}
