import Foundation
import GistPadInterface
import Observation

@MainActor
@Observable
final class NotebookLayoutPreferences {
  private(set) var preferredMode: NoteMode
  private(set) var compactMode: NoteMode
  @ObservationIgnored private let defaults: UserDefaults

  private static let modeKey = "dev.gistpad.workspace.note-mode"
  private static let compactModeKey = "dev.gistpad.workspace.compact-note-mode"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    preferredMode = defaults.string(forKey: Self.modeKey).flatMap(NoteMode.init(rawValue:)) ?? .split
    let storedCompact = defaults.string(forKey: Self.compactModeKey).flatMap(NoteMode.init(rawValue:))
    compactMode = storedCompact == .source ? .source : .reading
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
