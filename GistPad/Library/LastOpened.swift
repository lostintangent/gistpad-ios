import Foundation
import GistPadSync

struct FileReference: Codable, Equatable, Sendable {
  let gistID: String?
  let filename: String
  let draftID: UUID?
}

@MainActor
final class LastOpened {
  private let defaults: UserDefaults?
  private var memory: [UUID: FileReference] = [:]

  init(defaults: UserDefaults? = nil) { self.defaults = defaults }

  /// The file to reopen at launch. One that can't be read is simply forgotten.
  func selection(accountID: UUID) -> FileReference? {
    guard let defaults else { return memory[accountID] }
    return defaults.data(forKey: key(accountID)).flatMap {
      try? JSONDecoder().decode(FileReference.self, from: $0)
    }
  }

  func save(_ selection: FileReference, accountID: UUID) {
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

  /// Keeps its original name so the last-opened file survives the update.
  private func key(_ accountID: UUID) -> String {
    "notebook.selection.\(accountID.uuidString)"
  }
}

struct LocalState: Sendable {
  let cache: CachedLibrary?
  let drafts: [Draft]
}
