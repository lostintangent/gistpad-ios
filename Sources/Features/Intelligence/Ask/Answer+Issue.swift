import Foundation

extension Answer {
    /// Why a reply's prose can't be shown, so Ask asks the model again.
    package enum Issue: String, Sendable {
        case unverifiedProseQuote
        case internalIdentifier
        case thirdPerson
        case markupLeak
    }
}

extension Answer.Reply {
    /// Why this prose can't be shown, or nil when it can.
    package func issue(answering instruction: String = "", in source: String) -> Answer.Issue? {
        func isSupportedQuote(_ quote: String) -> Bool {
            guard quote.first?.isLetter == true, quote.last?.isLetter == true else {
                return !source.exactRanges(of: quote).isEmpty
            }
            let pattern = #"(?<![\p{L}\p{N}])"#
                + NSRegularExpression.escapedPattern(for: quote)
                + #"(?![\p{L}\p{N}])"#
            return source.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let quotations = [
            /["“]([^"”\n]+)["”]/, /(?:^|[\s(\[])['‘]([^\n]+?)['’](?=$|[\s).,!?:;\]])/,
            /[「『«]([^」』»\n]+)[」』»]/,
        ]
        for quotation in quotations {
            for match in prose.matches(of: quotation) where !isSupportedQuote(String(match.output.1)) {
                return .unverifiedProseQuote
            }
        }
        func isAuthored(_ text: String) -> Bool {
            source.localizedCaseInsensitiveContains(text)
                || instruction.localizedCaseInsensitiveContains(text)
        }
        for match in prose.matches(
            of:
                /(?i)\b(?:blockIDs?|firstOrderedItem|evidenceBlocks|sourceUTF16|requestID|listID|taskIDs?|(?:source|evidence) blocks?|block\s*#?\s*(?:\d+|one|two|three|four)|(?:first|second|third) block)\b/
        ) where !isAuthored(String(match.output)) {
            return .internalIdentifier
        }
        for match in prose.matches(of: /(?i)\bthe (?:user|creator)\b/)
        where !isAuthored(String(match.output)) {
            return .thirdPerson
        }
        for match in prose.matches(of: /(?i)<\/?[a-z][a-z0-9-]*(?:\s+[^>]*)?>|[{}]/)
        where !source.contains(String(match.output)) {
            return .markupLeak
        }
        return nil
    }
}
