import GistPadEditor
import GistPadInterface
import OSLog
import UIKit

@MainActor
final class NotebookSourceDiagnostics {
  struct ViewState: Codable {
    let type: String
    let bounds: CGRect
    let frameInWindow: CGRect?
    let hidden: Bool
    let alpha: CGFloat
    let opacity: Float
    let presentationOpacity: Float?
  }

  struct Snapshot: Codable {
    let timestamp: Date
    let stage: String
    let scenePhase: String
    let mode: String
    let session: UUID
    let sourceBytes: Int
    let editorBytes: Int
    let sourceMatchesEditor: Bool
    let generation: UInt64
    let windowAttached: Bool
    let windowKey: Bool
    let windowSceneState: String?
    let windowBounds: CGRect?
    let windowSafeArea: [CGFloat]?
    let firstResponder: Bool
    let editable: Bool
    let composing: Bool
    let writingToolsActive: Bool
    let markedText: Bool
    let contentSize: CGSize
    let contentOffset: CGPoint
    let contentInset: [CGFloat]
    let adjustedContentInset: [CGFloat]
    let insetAdjustmentBehavior: Int
    let textContainerInset: [CGFloat]
    let textContainerSize: CGSize
    let selectedLocation: Int
    let selectedLength: Int
    let textViewportBounds: CGRect?
    let hasTextViewportRange: Bool
    let firstForegroundRGBA: [CGFloat]?
    let ancestors: [ViewState]
  }

  enum Stage: String { case requested, settled, disappeared }

  private(set) var snapshots: [Snapshot] = []
  private let fileURL: URL
  private let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "SourcePresentation")

  init(fileURL: URL = URL.applicationSupportDirectory.appending(
    path: "EditorDiagnostics/latest.json", directoryHint: .notDirectory)
  ) {
    self.fileURL = fileURL
  }

  func record(_ session: DocumentSession, mode: NoteMode, phase: String, stage: Stage) {
    if stage == .requested, let previous = snapshots.last,
      previous.session == session.viewIdentity, previous.mode == mode.rawValue,
      previous.scenePhase == phase, previous.stage != Stage.disappeared.rawValue
    { return }
    let editor = session.textView
    let window = editor.window
    let viewport = editor.textLayoutManager?.textViewportLayoutController
    var foreground: [CGFloat]?
    if editor.textStorage.length > 0,
      let color = editor.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
    {
      var red: CGFloat = 0
      var green: CGFloat = 0
      var blue: CGFloat = 0
      var alpha: CGFloat = 0
      if color.resolvedColor(with: editor.traitCollection).getRed(
        &red, green: &green, blue: &blue, alpha: &alpha)
      { foreground = [red, green, blue, alpha] }
    }
    snapshots.append(Snapshot(
      timestamp: Date(), stage: stage.rawValue, scenePhase: phase, mode: mode.rawValue,
      session: session.viewIdentity, sourceBytes: session.text.utf8.count,
      editorBytes: editor.text.utf8.count,
      sourceMatchesEditor: session.text.utf8.elementsEqual(editor.text.utf8),
      generation: session.generation, windowAttached: window != nil,
      windowKey: window?.isKeyWindow == true,
      windowSceneState: window?.windowScene.map { String(describing: $0.activationState) },
      windowBounds: window?.bounds, windowSafeArea: window.map { edges($0.safeAreaInsets) },
      firstResponder: editor.isFirstResponder, editable: editor.isEditable,
      composing: session.isComposing, writingToolsActive: session.writingToolsActive,
      markedText: editor.markedTextRange != nil,
      contentSize: editor.contentSize, contentOffset: editor.contentOffset,
      contentInset: edges(editor.contentInset), adjustedContentInset: edges(editor.adjustedContentInset),
      insetAdjustmentBehavior: editor.contentInsetAdjustmentBehavior.rawValue,
      textContainerInset: edges(editor.textContainerInset), textContainerSize: editor.textContainer.size,
      selectedLocation: editor.selectedRange.location, selectedLength: editor.selectedRange.length,
      textViewportBounds: viewport?.viewportBounds, hasTextViewportRange: viewport?.viewportRange != nil,
      firstForegroundRGBA: foreground,
      ancestors: sequence(first: editor as UIView, next: { $0.superview }).prefix(32).map { view in
        ViewState(
          type: String(describing: type(of: view)), bounds: view.bounds,
          frameInWindow: window.map { view.convert(view.bounds, to: $0) },
          hidden: view.isHidden, alpha: view.alpha, opacity: view.layer.opacity,
          presentationOpacity: view.layer.presentation()?.opacity)
      }))
    snapshots = Array(snapshots.suffix(48))
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
      encoder.nonConformingFloatEncodingStrategy = .convertToString(
        positiveInfinity: "infinity", negativeInfinity: "-infinity", nan: "nan")
      try encoder.encode(snapshots).write(to: fileURL, options: .atomic)
    } catch {
      logger.error(
        "Source diagnostics could not be written: \(String(reflecting: type(of: error)), privacy: .public)")
    }
  }

  private func edges(_ value: UIEdgeInsets) -> [CGFloat] {
    [value.top, value.left, value.bottom, value.right]
  }
}
