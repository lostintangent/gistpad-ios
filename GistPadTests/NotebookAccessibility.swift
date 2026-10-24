import UIKit

@MainActor
func notebookAccessibilityElement(_ identifier: String, in root: NSObject) -> NSObject? {
  var visited = Set<ObjectIdentifier>()
  func find(in object: NSObject) -> NSObject? {
    guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
    if (object as? any UIAccessibilityIdentification)?.accessibilityIdentifier == identifier {
      return object
    }
    let count = object.accessibilityElementCount()
    if count != NSNotFound, count > 0 {
      for index in 0..<count {
        if let child = object.accessibilityElement(at: index) as? NSObject,
          let found = find(in: child)
        {
          return found
        }
      }
    }
    if let view = object as? UIView {
      for child in view.subviews {
        if let found = find(in: child) { return found }
      }
    }
    return nil
  }
  return find(in: root)
}
