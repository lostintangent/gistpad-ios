import Foundation

public enum ThreeWayMerge {
    public static func merge(base: String, local: String, remote: String) -> String? {
        if sourceEqual(local, remote) { return local }
        if sourceEqual(base, remote) { return local }
        if sourceEqual(base, local) { return remote }
        let original = lines(base)
        let localHunks = hunks(from: original, to: lines(local))
        let remoteHunks = hunks(from: original, to: lines(remote))
        var combined = localHunks
        for remote in remoteHunks {
            if combined.contains(remote) { continue }
            guard !localHunks.contains(where: { overlaps($0.range, remote.range) }) else { return nil }
            combined.append(remote)
        }
        var result = original
        for hunk in combined.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(hunk.range, with: hunk.replacement)
        }
        return result.map(\.text).joined(separator: "\n")
    }

    private struct Line: Equatable {
        let text: String
        static func == (lhs: Line, rhs: Line) -> Bool { sourceEqual(lhs.text, rhs.text) }
    }

    private struct Hunk: Equatable {
        let range: Range<Int>
        let replacement: [Line]
    }

    private static func lines(_ text: String) -> [Line] {
        text.components(separatedBy: "\n").map { Line(text: $0) }
    }

    private static func hunks(from base: [Line], to changed: [Line]) -> [Hunk] {
        let difference = changed.difference(from: base)
        var removals: Set<Int> = []
        var insertions: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }
        var result: [Hunk] = []
        var baseIndex = 0
        var changedIndex = 0
        var start: Int?
        var replacement: [Line] = []
        while baseIndex < base.count || changedIndex < changed.count {
            if insertions.contains(changedIndex) {
                if start == nil { start = baseIndex }
                replacement.append(changed[changedIndex])
                changedIndex += 1
            } else if removals.contains(baseIndex) {
                if start == nil { start = baseIndex }
                baseIndex += 1
            } else {
                if let lower = start {
                    result.append(Hunk(range: lower..<baseIndex, replacement: replacement))
                    start = nil
                    replacement = []
                }
                baseIndex += 1
                changedIndex += 1
            }
        }
        if let start { result.append(Hunk(range: start..<baseIndex, replacement: replacement)) }
        return result
    }

    private static func overlaps(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
        if lhs.isEmpty { return rhs.lowerBound <= lhs.lowerBound && lhs.lowerBound <= rhs.upperBound }
        if rhs.isEmpty { return lhs.lowerBound <= rhs.lowerBound && rhs.lowerBound <= lhs.upperBound }
        return lhs.overlaps(rhs)
    }
}
