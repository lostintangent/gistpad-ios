import Foundation
import GistPadSync

struct NotebookSelection: Codable, Equatable, Sendable {
  let gistID: String?
  let filename: String
  let draftID: UUID?
}

@MainActor
final class NotebookSelectionStore {
  private let defaults: UserDefaults?
  private var memory: [UUID: NotebookSelection] = [:]

  init(defaults: UserDefaults? = nil) { self.defaults = defaults }

  /// The note to reopen at launch. One that can't be read is simply forgotten.
  func selection(accountID: UUID) -> NotebookSelection? {
    guard let defaults else { return memory[accountID] }
    return defaults.data(forKey: key(accountID)).flatMap {
      try? JSONDecoder().decode(NotebookSelection.self, from: $0)
    }
  }

  func save(_ selection: NotebookSelection, accountID: UUID) {
    guard let defaults else {
      memory[accountID] = selection
      return
    }
    defaults.set(try? JSONEncoder().encode(selection), forKey: key(accountID))
  }

  func clear(accountID: UUID) {
    defaults?.removeObject(forKey: key(accountID))
    memory[accountID] = nil
  }

  private func key(_ accountID: UUID) -> String {
    "notebook.selection.\(accountID.uuidString)"
  }
}

struct NotebookLocalState: Sendable {
  let library: CachedLibrary?
  let drafts: [Draft]
}
