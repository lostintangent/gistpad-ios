import Foundation
import GistPadInterface
import Observation

@MainActor
@Observable
final class LayoutPreferences {
  private(set) var preferredMode: FileMode
  private(set) var compactMode: FileMode
  private var librarySections: [String: Set<LibrarySection>]
  private var collapsedPinned: Set<String>
  @ObservationIgnored private let defaults: UserDefaults

  private static let modeKey = "dev.gistpad.workspace.note-mode"
  private static let compactModeKey = "dev.gistpad.workspace.compact-note-mode"
  private static let librarySectionsKey = "dev.gistpad.workspace.expanded-library-collections"
  private static let collapsedPinnedKey = "dev.gistpad.workspace.collapsed-pinned-library"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    preferredMode = defaults.string(forKey: Self.modeKey).flatMap(FileMode.init(rawValue:)) ?? .split
    let storedCompact = defaults.string(forKey: Self.compactModeKey).flatMap(FileMode.init(rawValue:))
    compactMode = storedCompact == .edit ? .edit : .preview
    let savedSections = defaults.dictionary(forKey: Self.librarySectionsKey) ?? [:]
    librarySections = savedSections.compactMapValues { value in
      guard let names = value as? [String] else { return nil }
      return Set(names.compactMap(LibrarySection.init(rawValue:)).filter { $0 != .gists })
    }
    collapsedPinned = Set(defaults.stringArray(forKey: Self.collapsedPinnedKey) ?? [])
  }

  func expandedSections(accountID: UUID) -> Set<LibrarySection> {
    librarySections[accountID.uuidString] ?? []
  }

  func setExpandedSections(_ sections: Set<LibrarySection>, accountID: UUID) {
    let secondary = sections.subtracting([.gists])
    guard expandedSections(accountID: accountID) != secondary else { return }
    librarySections[accountID.uuidString] = secondary
    defaults.set(
      librarySections.mapValues { $0.map(\.rawValue).sorted() },
      forKey: Self.librarySectionsKey)
  }

  func isPinnedExpanded(accountID: UUID) -> Bool {
    !collapsedPinned.contains(accountID.uuidString)
  }

  func setPinnedExpanded(_ expanded: Bool, accountID: UUID) {
    var collapsed = collapsedPinned
    if expanded {
      collapsed.remove(accountID.uuidString)
    } else {
      collapsed.insert(accountID.uuidString)
    }
    guard collapsed != collapsedPinned else { return }
    collapsedPinned = collapsed
    defaults.set(collapsed.sorted(), forKey: Self.collapsedPinnedKey)
  }

  static func allowsSplit(availableWidth: CGFloat) -> Bool {
    availableWidth.isFinite && availableWidth >= 641
  }

  func select(_ mode: FileMode) {
    preferredMode = mode
    defaults.set(mode.rawValue, forKey: Self.modeKey)
    if mode != .split {
      compactMode = mode
      defaults.set(mode.rawValue, forKey: Self.compactModeKey)
    }
  }

  func initialMode(isUnpublished: Bool) -> FileMode {
    isUnpublished ? .edit : compactMode
  }

  func presentedMode(
    availableWidth: CGFloat, sessionMode: FileMode, isEditing: Bool, canEdit: Bool
  ) -> FileMode {
    guard canEdit else { return .preview }
    if preferredMode == .split {
      if Self.allowsSplit(availableWidth: availableWidth) { return .split }
      if isEditing { return .edit }
    }
    return sessionMode == .split ? compactMode : sessionMode
  }
}
