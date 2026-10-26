import Foundation
import GistPadInterface
import Observation

@MainActor
@Observable
final class NotebookLayoutPreferences {
  private(set) var preferredMode: NoteMode
  private(set) var compactMode: NoteMode
  private var libraryCollections: [String: Set<LibraryCollection>]
  @ObservationIgnored private let defaults: UserDefaults

  private static let modeKey = "dev.gistpad.workspace.note-mode"
  private static let compactModeKey = "dev.gistpad.workspace.compact-note-mode"
  private static let libraryCollectionsKey = "dev.gistpad.workspace.expanded-library-collections"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    preferredMode = defaults.string(forKey: Self.modeKey).flatMap(NoteMode.init(rawValue:)) ?? .split
    let storedCompact = defaults.string(forKey: Self.compactModeKey).flatMap(NoteMode.init(rawValue:))
    compactMode = storedCompact == .source ? .source : .reading
    let savedCollections = defaults.dictionary(forKey: Self.libraryCollectionsKey) ?? [:]
    libraryCollections = savedCollections.compactMapValues { value in
      guard let names = value as? [String] else { return nil }
      return Set(names.compactMap(LibraryCollection.init(rawValue:)).filter { $0 != .gists })
    }
  }

  func expandedCollections(accountID: UUID) -> Set<LibraryCollection> {
    libraryCollections[accountID.uuidString] ?? []
  }

  func setExpandedCollections(_ collections: Set<LibraryCollection>, accountID: UUID) {
    let secondary = collections.subtracting([.gists])
    guard expandedCollections(accountID: accountID) != secondary else { return }
    libraryCollections[accountID.uuidString] = secondary
    defaults.set(
      libraryCollections.mapValues { $0.map(\.rawValue).sorted() },
      forKey: Self.libraryCollectionsKey)
  }

  static func allowsSplit(availableWidth: CGFloat) -> Bool {
    availableWidth.isFinite && availableWidth >= 641
  }

  func select(_ mode: NoteMode) {
    preferredMode = mode
    defaults.set(mode.rawValue, forKey: Self.modeKey)
    if mode != .split {
      compactMode = mode
      defaults.set(mode.rawValue, forKey: Self.compactModeKey)
    }
  }

  func initialMode(isUnpublished: Bool) -> NoteMode {
    isUnpublished ? .source : compactMode
  }

  func presentedMode(
    availableWidth: CGFloat, sessionMode: NoteMode, isEditing: Bool, canEdit: Bool
  ) -> NoteMode {
    guard canEdit else { return .reading }
    if preferredMode == .split {
      if Self.allowsSplit(availableWidth: availableWidth) { return .split }
      if isEditing { return .source }
    }
    return sessionMode == .split ? compactMode : sessionMode
  }
}
