import UIKit

@testable import GistPad

@MainActor
func notebookAccessibilityElement(_ identifier: String, in root: NSObject) -> NSObject? {
  GistPad.notebookAccessibilityElement(identifier, in: root)
}
