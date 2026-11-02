import GistPadEditor
import Observation
import SwiftUI
import Testing
import UIKit

@testable import GistPad

@Suite(.serialized)
@MainActor
struct DuoPostureProbe {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["GISTPAD_FOLD_PROBE"] == "1"))
  func markedTextThroughRealSimulatorPostures() async throws {
    let original = EditorFixture.markdown
    let session = DocumentSession(documentID: "manual-fold-probe", text: original)
    let probe = PostureProbeState(session: session)
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(rootView: PostureProbeView(probe: probe))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(500))
    session.textView.becomeFirstResponder()
    session.textView.selectedRange = NSRange(location: 0, length: 0)
    session.textView.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0))
    probe.captureBaseline()
    let coverWidth = Int(window.bounds.width)
    var expanded = false
    var returnedToCover = false
    let deadline = ContinuousClock.now.advanced(by: .seconds(120))
    while !returnedToCover && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(250))
      probe.record()
      if let width = probe.samples.last?.width {
        if width > coverWidth { expanded = true }
        if expanded && width == coverWidth { returnedToCover = true }
      }
    }
    #expect(returnedToCover, "Use Device Hub: Closed, Open, Partially Open, Closed.")
    #expect(probe.samples.count >= 4)
    #expect(probe.samples.allSatisfy { $0.valid })
    #expect(
      Set(probe.samples.map(\.width)).count >= 2, "A width-only fixture is not posture evidence.")
    session.textView.unmarkText()
    session.textView.undoManager?.undo()
    #expect(session.textView.text.utf8.elementsEqual(original.utf8))
    Attachment.record(
      probe.samples.map(\.description).joined(separator: "\n"),
      named: "duo-posture-checkpoints.txt")
  }
}

@MainActor
@Observable
private final class PostureProbeState {
  let session: DocumentSession
  var samples: [PostureSample] = []
  private var expectedText: [UInt8] = []
  private var expectedSelection = NSRange(location: 0, length: 0)
  private var identity: ObjectIdentifier?

  init(session: DocumentSession) { self.session = session }

  func captureBaseline() {
    expectedText = Array(session.textView.text.utf8)
    expectedSelection = session.textView.selectedRange
    identity = ObjectIdentifier(session.textView)
  }

  func record() {
    let valid =
      expectedText.elementsEqual(session.textView.text.utf8)
      && session.textView.selectedRange == expectedSelection
      && session.textView.markedTextRange != nil
      && session.textView.isFirstResponder
      && ObjectIdentifier(session.textView) == identity
    samples.append(
      PostureSample(
        number: samples.count + 1,
        width: Int(session.textView.window?.bounds.width ?? 0),
        selection: session.textView.selectedRange,
        marked: session.textView.markedTextRange != nil,
        identity: String(session.viewIdentity.uuidString.prefix(8)),
        valid: valid))
  }
}

private struct PostureSample {
  let number: Int
  let width: Int
  let selection: NSRange
  let marked: Bool
  let identity: String
  let valid: Bool

  var description: String {
    "Checkpoint \(number): width \(width), selection \(selection), marked \(marked), editor \(identity), exact bytes/selection/identity \(valid)"
  }
}

private struct PostureProbeView: View {
  let probe: PostureProbeState

  var body: some View {
    NavigationStack {
      MarkdownEditorView(session: probe.session)
        .navigationTitle("Simulator posture probe")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
          VStack(alignment: .leading, spacing: 12) {
            Text("Programmatic Japanese marked text, not a real keyboard candidate session.")
              .font(.footnote)
            Text(
              "Editor \(probe.session.viewIdentity.uuidString.prefix(8)) · \(probe.samples.count) checkpoints"
            )
            .font(.footnote.monospaced())
            Text("Checkpoints are automatic. Use Device Hub: Open, Partially Open, Closed.")
              .font(.footnote)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
          .background(.bar)
        }
    }
  }
}
