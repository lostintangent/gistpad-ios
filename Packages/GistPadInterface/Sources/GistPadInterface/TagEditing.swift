import Foundation

public enum TagEdit: Equatable, Sendable {
    case setMembership(tagID: String, included: Bool)
    case upsert(LibraryTag)
    case delete(tagID: String)
}

enum TagEditingError: LocalizedError {
    case emptyName
    case duplicateName

    var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "Give this tag a name.", bundle: .module)
        case .duplicateName: String(localized: "A tag with this name already exists.", bundle: .module)
        }
    }
}

struct TagEditorDraft {
    private let originalTags: [LibraryTag]
    private let originalSelection: Set<String>
    private var attemptedUpserts: Set<String> = []
    private var attemptedMemberships: Set<String> = []
    private var attemptedDeletions: Set<String> = []
    private(set) var tags: [LibraryTag]
    var selectedTagIDs: Set<String>

    init(tags: [LibraryTag], selectedTagIDs: Set<String>) {
        originalTags = tags
        originalSelection = selectedTagIDs
        self.tags = tags
        self.selectedTagIDs = selectedTagIDs
    }

    mutating func upsert(_ tag: LibraryTag) throws {
        let name = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TagEditingError.emptyName }
        guard !tags.contains(where: {
            $0.id != tag.id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { throw TagEditingError.duplicateName }
        let updated = LibraryTag(id: tag.id, name: name, colorHex: tag.colorHex)
        if let index = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[index] = updated
        } else {
            tags.append(updated)
            selectedTagIDs.insert(updated.id)
        }
    }

    mutating func delete(_ tag: LibraryTag) {
        tags.removeAll { $0.id == tag.id }
        selectedTagIDs.remove(tag.id)
    }

    mutating func recordAttempt(_ edits: [TagEdit]) {
        for edit in edits {
            switch edit {
            case .upsert(let tag): attemptedUpserts.insert(tag.id)
            case .setMembership(let id, _): attemptedMemberships.insert(id)
            case .delete(let id): attemptedDeletions.insert(id)
            }
        }
    }

    var hasAttemptedChanges: Bool {
        !attemptedUpserts.isEmpty || !attemptedMemberships.isEmpty || !attemptedDeletions.isEmpty
    }

    var edits: [TagEdit] {
        let remaining = Set(tags.map(\.id))
        var result = tags.filter { tag in
            !originalTags.contains(tag) || attemptedUpserts.contains(tag.id) || attemptedDeletions.contains(tag.id)
        }
            .sorted { $0.id < $1.id }.map(TagEdit.upsert)
        for id in remaining.sorted() where originalSelection.contains(id) != selectedTagIDs.contains(id)
            || attemptedMemberships.contains(id) || attemptedDeletions.contains(id) {
            result.append(.setMembership(tagID: id, included: selectedTagIDs.contains(id)))
        }
        result += Set(originalTags.map(\.id)).union(attemptedUpserts).union(attemptedDeletions)
            .subtracting(remaining).sorted().map { .delete(tagID: $0) }
        return result
    }
}
