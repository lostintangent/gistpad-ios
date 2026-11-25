import Foundation
import Markdown

package struct Proposal: Sendable {
    let snapshot: FileSnapshot
    package let changes: [Change]
    fileprivate let safetyInstruction: String?

    package var omittedCount: Int { changes.count(where: { $0.range == nil }) }
    var canApply: Bool { changes.contains { $0.canApply } }

    init(
        snapshot: FileSnapshot, scopedCandidates: [(Change, NSRange)],
        safetyInstruction: String? = nil
    ) {
        self.snapshot = snapshot
        self.safetyInstruction = safetyInstruction
        var anchored = scopedCandidates.map { change, scope in
            var change = change
            // An empty quote inserts at an empty scope.
            let matches =
                change.quote.isEmpty
                ? (scope.length == 0 && Range(scope, in: snapshot.source) != nil ? [scope] : [])
                : snapshot.source.exactRanges(
                    of: change.quote, within: scope, before: change.before, after: change.after)
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

    init(
        snapshot: FileSnapshot, changes: [Change], safetyInstruction: String? = nil
    ) {
        self.snapshot = snapshot
        self.changes = changes
        self.safetyInstruction = safetyInstruction
    }

    func dismissing(changeID: UUID) -> Proposal {
        Proposal(
            snapshot: snapshot, changes: changes.filter { $0.id != changeID },
            safetyInstruction: safetyInstruction)
    }

    package func application(
        to current: FileSnapshot, changeID: UUID? = nil
    ) throws -> Applied {
        guard current == snapshot else { throw IntelligenceError.staleSnapshot }
        let selected = changes.filter { $0.canApply && (changeID == nil || $0.id == changeID) }
        guard !selected.isEmpty else { throw IntelligenceError.noApplicableChanges }
        var source = snapshot.source
        for change in selected.sorted(by: { ($0.range?.location ?? 0) > ($1.range?.location ?? 0) }) {
            guard let range = change.range, let replacement = change.replacement,
                let swiftRange = Range(range, in: source),
                source[swiftRange].utf8.elementsEqual(change.quote.utf8)
            else { throw IntelligenceError.staleSnapshot }
            source.replaceSubrange(swiftRange, with: replacement)
        }
        try validateApplication(source, changes: selected)
        return Applied(
            proposal: self, source: source,
            applied: selected.sorted { ($0.range?.location ?? 0) < ($1.range?.location ?? 0) })
    }

    private func validateApplication(_ replacement: String, changes: [Change]) throws {
        let source = snapshot.source
        guard let safetyInstruction, !source.isEmpty else { return }
        let document = MarkdownDocument(source)
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
            if let replacement = change.replacement, !request.isEmpty,
                Self.normalized(replacement) == request
            {
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
        let replacement: String?
        let reason: String
        /// The model's context around the quote, to tell repeats apart.
        var before = ""
        var after = ""
        package internal(set) var range: NSRange?

        var canApply: Bool {
            range != nil
                && replacement.map { !quote.utf8.elementsEqual($0.utf8) } == true
        }
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

        /// The changes left on the note this application produced, re-verified at their new ranges.
        func remaining(on snapshot: FileSnapshot) -> Proposal {
            let appliedIDs = Set(applied.map(\.id))
            let remaining = proposal.changes.filter { !appliedIDs.contains($0.id) }.map { change in
                var change = change
                let range = change.range.map {
                    NSRange(location: mappedOffset($0.location, trailing: false), length: $0.length)
                }
                let verified =
                    range.flatMap { Range($0, in: source) }.map {
                        source[$0].utf8.elementsEqual(change.quote.utf8)
                    } ?? false
                change.range = verified ? range : nil
                return change
            }
            return Proposal(
                snapshot: snapshot, changes: remaining,
                safetyInstruction: proposal.safetyInstruction)
        }

        private func mappedOffset(_ position: Int, trailing: Bool) -> Int {
            var shift = 0
            var mapped: Int?
            for change in applied {
                guard let range = change.range, let replacement = change.replacement else { continue }
                if position < range.location { break }
                if position < NSMaxRange(range) {
                    mapped = range.location + shift + (trailing ? replacement.utf16.count : 0)
                    break
                }
                shift += replacement.utf16.count - range.length
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
    /// Where `quote` appears byte for byte, within `scope` and between `before` and `after`.
    func exactRanges(
        of quote: String, within scope: NSRange? = nil, before: String = "", after: String = ""
    ) -> [NSRange] {
        let text = self as NSString
        let scope = scope ?? NSRange(location: 0, length: text.length)
        guard !quote.isEmpty, Range(scope, in: self) != nil else { return [] }
        var result: [NSRange] = []
        var cursor = scope.location
        while cursor < NSMaxRange(scope) {
            let search = NSRange(location: cursor, length: NSMaxRange(scope) - cursor)
            let match = text.range(of: quote, options: .literal, range: search)
            guard match.location != NSNotFound else { break }
            if let swiftRange = Range(match, in: self),
                self[swiftRange].utf8.elementsEqual(quote.utf8),
                match.location >= before.utf16.count,
                NSMaxRange(match) + after.utf16.count <= text.length
            {
                let prefix = Range(
                    NSRange(location: match.location - before.utf16.count, length: before.utf16.count),
                    in: self)
                let suffix = Range(
                    NSRange(location: NSMaxRange(match), length: after.utf16.count), in: self)
                if let prefix, let suffix,
                    self[prefix].utf8.elementsEqual(before.utf8),
                    self[suffix].utf8.elementsEqual(after.utf8)
                {
                    result.append(match)
                }
            }
            cursor = match.location + 1
        }
        return result
    }
}
