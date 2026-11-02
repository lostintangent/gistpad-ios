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

  func selection(accountID: UUID) throws -> NotebookSelection? {
    guard let defaults else { return memory[accountID] }
    guard let data = defaults.data(forKey: key(accountID)) else { return nil }
    return try JSONDecoder().decode(NotebookSelection.self, from: data)
  }

  func save(_ selection: NotebookSelection, accountID: UUID) throws {
    let data = try JSONEncoder().encode(selection)
    if let defaults {
      defaults.set(data, forKey: key(accountID))
    } else {
      memory[accountID] = selection
    }
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
  let library: CachedLibrarySnapshot?
  let drafts: [DraftSnapshot]
}
