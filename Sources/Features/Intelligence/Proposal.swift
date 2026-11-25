import Foundation
import Markdown

package struct Proposal: Sendable {
    let document: MarkdownDocument
    package let changes: [Change]
    private let safetyInstruction: String?

    package var omittedCount: Int { changes.count(where: { $0.range == nil }) }
    var canApply: Bool { changes.contains { $0.canApply } }

    init(
        document: MarkdownDocument, scopedCandidates: [(Change, NSRange)],
        safetyInstruction: String? = nil
    ) {
        self.document = document
        self.safetyInstruction = safetyInstruction
        var anchored = scopedCandidates.map { change, scope in
            var change = change
            // An empty quote inserts at an empty scope.
            let matches =
                change.quote.isEmpty
                ? (scope.length == 0 && Range(scope, in: document.text) != nil ? [scope] : [])
                : document.text.exactRanges(of: change.quote, within: scope)
            change.range = matches.count == 1 ? matches[0] : nil
            return change
        }
        var overlapping = Set<Int>()
        for first in anchored.indices {
            guard let left = anchored[first].range else { continue }
            for second in anchored.indices where second > first {
                guard let right = anchored[second].range,
                    NSIntersectionRange(left, right).length > 0
                        || (left.length == 0 && right.length == 0 && left.location == right.location)
                        || (left.length == 0 && right.location <= left.location
                            && left.location <= NSMaxRange(right))
                        || (right.length == 0 && left.location <= right.location
                            && right.location <= NSMaxRange(left))
                else { continue }
                overlapping.insert(first)
                overlapping.insert(second)
            }
        }
        for index in overlapping { anchored[index].range = nil }
        changes = anchored
    }

    /// The note with every applicable change made.
    package func application() throws -> Applied {
        let selected = changes.filter(\.canApply)
        guard !selected.isEmpty else { throw IntelligenceError.noApplicableChanges }
        var source = document.text
        for change in selected.sorted(by: { ($0.range?.location ?? 0) > ($1.range?.location ?? 0) }) {
            guard let range = change.range, let swiftRange = Range(range, in: source),
                source[swiftRange].utf8.elementsEqual(change.quote.utf8)
            else { throw IntelligenceError.noteChanged }
            source.replaceSubrange(swiftRange, with: change.replacement)
        }
        try validateApplication(source, changes: selected)
        return Applied(
            proposal: self, source: source,
            applied: selected.sorted { ($0.range?.location ?? 0) < ($1.range?.location ?? 0) })
    }

    private func validateApplication(_ replacement: String, changes: [Change]) throws {
        let source = document.text
        guard let safetyInstruction, !source.isEmpty else { return }
        let original = document.listItems(movedBy: safetyInstruction)
        if !original.isEmpty {
            guard original.count == 1 else { throw IntelligenceError.invalidEdit }
            let result = MarkdownDocument(replacement)
            let matching = result.listItems(movedBy: safetyInstruction)
            guard matching.count == 1 else { throw IntelligenceError.invalidEdit }
            let heading = original[0].heading
            guard try Self.body(of: matching[0].item, in: result).utf8
                .elementsEqual(Self.body(of: original[0].item, in: document).utf8),
                !matching[0].heading.utf8.elementsEqual(heading.utf8),
                result.blocks.contains(where: {
                    $0.kind == .heading && result.text(in: $0.range).utf8.elementsEqual(heading.utf8)
                })
            else { throw IntelligenceError.invalidEdit }
        }
        let request = Self.normalized(safetyInstruction)
        for change in changes {
            if !request.isEmpty, Self.normalized(change.replacement) == request {
                throw IntelligenceError.unsafeEdit
            }
        }
        guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntelligenceError.unsafeEdit
        }
        let originalCount = source.count(where: { !$0.isWhitespace })
        let replacementCount = replacement.count(where: { !$0.isWhitespace })
        guard replacementCount <= min(12, originalCount / 4) else { return }
        let retained = TextDiff(before: source, after: replacement).before
            .filter { $0.kind == .unchanged }.reduce(0) { $0 + $1.text.utf8.count }
        if retained * 10 < source.utf8.count {
            throw IntelligenceError.unsafeEdit
        }
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }

    /// A list item's text from its box, or after its marker when it has none.
    private static func body(of item: MarkdownDocument.Block, in document: MarkdownDocument) throws -> String {
        guard let prefix = item.prefix else { throw IntelligenceError.invalidEdit }
        let start = item.box?.location ?? NSMaxRange(prefix)
        return document.text(in: NSRange(start..<NSMaxRange(item.range)))
    }
}

extension Proposal {
    /// A replacement for a quote, anchored at `range` once the quote is found exactly once.
    package struct Change: Identifiable, Sendable {
        package let id = UUID()
        let quote: String
        let replacement: String
        let reason: String
        package internal(set) var range: NSRange?

        var canApply: Bool { range != nil && !quote.utf8.elementsEqual(replacement.utf8) }
    }
}

extension Proposal {
    package struct Applied: Sendable {
        package let proposal: Proposal
        package let source: String
        package let applied: [Change]

        func mappedSelection(_ selection: NSRange) -> NSRange {
            let start = mappedOffset(selection.location, trailing: selection.length == 0)
            let end = mappedOffset(NSMaxRange(selection), trailing: true)
            return NSRange(location: start, length: max(0, end - start))
        }

        private func mappedOffset(_ position: Int, trailing: Bool) -> Int {
            var shift = 0
            var mapped: Int?
            for change in applied {
                guard let range = change.range else { continue }
                if position < range.location { break }
                if position < NSMaxRange(range) {
                    mapped = range.location + shift + (trailing ? change.replacement.utf16.count : 0)
                    break
                }
                shift += change.replacement.utf16.count - range.length
            }
            let text = source as NSString
            let offset = min(max(0, mapped ?? position + shift), text.length)
            guard offset > 0, offset < text.length else { return offset }
            let composed = text.rangeOfComposedCharacterSequence(at: offset)
            guard composed.location != offset else { return offset }
            return trailing ? NSMaxRange(composed) : composed.location
        }
    }
}

extension String {
    /// Where `quote` appears byte for byte within `scope`.
    func exactRanges(of quote: String, within scope: NSRange? = nil) -> [NSRange] {
        let text = self as NSString
        let scope = scope ?? NSRange(location: 0, length: text.length)
        guard !quote.isEmpty, Range(scope, in: self) != nil else { return [] }
        var result: [NSRange] = []
        var cursor = scope.location
        while cursor < NSMaxRange(scope) {
            let search = NSRange(location: cursor, length: NSMaxRange(scope) - cursor)
            let match = text.range(of: quote, options: .literal, range: search)
            guard match.location != NSNotFound else { break }
            if let swiftRange = Range(match, in: self), self[swiftRange].utf8.elementsEqual(quote.utf8) {
                result.append(match)
            }
            cursor = match.location + 1
        }
        return result
    }
}
