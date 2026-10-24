import GistPadAppearance
import SwiftUI
import UIKit

struct NotebookSceneAccent: UIViewRepresentable {
  let savedHex: String?

  func makeUIView(context: Context) -> NotebookSceneAccentView {
    NotebookSceneAccentView(accent: PersonalAccent(savedHex: savedHex))
  }

  func updateUIView(_ view: NotebookSceneAccentView, context: Context) {
    view.updateAccent(PersonalAccent(savedHex: savedHex))
  }
}

final class NotebookSceneAccentView: UIView {
  private var accent: PersonalAccent

  init(accent: PersonalAccent) {
    self.accent = accent
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    isAccessibilityElement = false
  }

  required init?(coder: NSCoder) { return nil }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    applyAccent()
  }

  func updateAccent(_ value: PersonalAccent) {
    guard value != accent else { return }
    accent = value
    applyAccent()
  }

  private func applyAccent() {
    guard let scene = window?.windowScene,
      scene.traitCollection[PersonalAccentTrait.self] != accent
    else { return }
    scene.traitOverrides[PersonalAccentTrait.self] = accent
  }
}
