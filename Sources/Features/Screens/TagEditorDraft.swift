import Foundation
import Store

public enum TagEdit: Equatable, Sendable {
    case setMembership(tagID: String, included: Bool)
    case upsert(Tag)
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
    private let originalTags: [Tag]
    private let originalSelection: Set<String>
    private(set) var tags: [Tag]
    var selectedTagIDs: Set<String>

    init(tags: [Tag], selectedTagIDs: Set<String>) {
        originalTags = tags
        originalSelection = selectedTagIDs
        self.tags = tags
        self.selectedTagIDs = selectedTagIDs
    }

    mutating func upsert(_ tag: Tag) throws {
        let name = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TagEditingError.emptyName }
        guard !tags.contains(where: {
            $0.id != tag.id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { throw TagEditingError.duplicateName }
        let updated = Tag(id: tag.id, name: name, colorHex: tag.colorHex)
        if let index = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[index] = updated
        } else {
            tags.append(updated)
            selectedTagIDs.insert(updated.id)
        }
    }

    mutating func delete(_ tag: Tag) {
        tags.removeAll { $0.id == tag.id }
        selectedTagIDs.remove(tag.id)
    }

    /// Every save sends the whole difference from the original, so a retry resends it as is.
    var edits: [TagEdit] {
        let remaining = Set(tags.map(\.id))
        var result = tags.filter { !originalTags.contains($0) }
            .sorted { $0.id < $1.id }.map(TagEdit.upsert)
        for id in remaining.sorted() where originalSelection.contains(id) != selectedTagIDs.contains(id) {
            result.append(.setMembership(tagID: id, included: selectedTagIDs.contains(id)))
        }
        result += Set(originalTags.map(\.id)).subtracting(remaining).sorted().map { .delete(tagID: $0) }
        return result
    }
}
