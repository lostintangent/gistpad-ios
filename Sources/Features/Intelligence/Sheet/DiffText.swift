import SwiftUI

enum DiffText {
  static func attributed(_ runs: [TextDiff.Run]) -> AttributedString {
    var result = AttributedString()
    for run in runs {
      var text = AttributedString(run.text)
      switch run.kind {
      case .unchanged:
        text.foregroundColor = .primary
      case .removed:
        text.foregroundColor = .secondary
        text.strikethroughStyle = Text.LineStyle(pattern: .solid)
      case .added:
        text.foregroundColor = .primary
        text.font = .body.weight(.semibold)
        text.underlineStyle = Text.LineStyle(pattern: .solid)
      }
      result += text
    }
    return result
  }
}
