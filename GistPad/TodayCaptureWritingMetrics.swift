#if DEBUG
import UIKit

struct TodayCaptureWritingMetrics: Equatable {
  let frame: CGRect
  let visibleHeight: CGFloat
  let lineHeight: CGFloat
  let characterCount: Int

  var visibleLineCount: CGFloat { visibleHeight / lineHeight }

  @MainActor
  init?(window: UIWindow, keyboardHeight: CGFloat) {
    func focusedEditor(in view: UIView) -> UITextView? {
      if let editor = view as? UITextView, editor.isFirstResponder { return editor }
      return view.subviews.lazy.compactMap { focusedEditor(in: $0) }.first
    }

    guard let editor = focusedEditor(in: window), let font = editor.font,
      font.lineHeight > 0
    else { return nil }
    frame = editor.convert(editor.bounds, to: window)
    let bottom = min(frame.maxY, window.bounds.maxY - keyboardHeight)
    visibleHeight = max(
      0, bottom - max(frame.minY, window.safeAreaInsets.top)
        - editor.textContainerInset.top - editor.textContainerInset.bottom)
    lineHeight = font.lineHeight
    characterCount = editor.text.count
  }
}
#endif
