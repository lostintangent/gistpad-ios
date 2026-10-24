import GistPadEditor
import GistPadInterface
import Testing
import UIKit

@testable import GistPad

@MainActor
struct NotebookSourceDiagnosticsTests {
  @Test func presentationRecordsContainGeometryButNoSourceOrDocumentIdentity() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer {
      do { try FileManager.default.removeItem(at: directory) }
      catch { Issue.record(error) }
    }
    let file = directory.appending(path: "latest.json")
    let source = "# PRIVATE SOURCE 987\n\nA private thought."
    let document = "PRIVATE ACCOUNT/PRIVATE GIST/PRIVATE FILE"
    let session = DocumentSession(documentID: document, text: source)
    let selection = session.textView.selectedRange
    let diagnostics = NotebookSourceDiagnostics(fileURL: file)
    diagnostics.record(session, mode: .source, phase: "active", stage: .settled)
    let data = try Data(contentsOf: file)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("PRIVATE"))
    #expect(!json.contains("private thought"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "infinity", negativeInfinity: "-infinity", nan: "nan")
    let record = try #require(try decoder.decode([NotebookSourceDiagnostics.Snapshot].self, from: data).first)
    #expect(record.sourceBytes == source.utf8.count)
    #expect(record.editorBytes == source.utf8.count)
    #expect(record.sourceMatchesEditor)
    #expect(!record.windowAttached)
    #expect(record.ancestors.count == 1)
    #expect(record.mode == NoteMode.source.rawValue)
    #expect(record.stage == "settled")
    #expect(session.text.utf8.elementsEqual(source.utf8))
    #expect(session.textView.selectedRange == selection)
    #expect(session.generation == 0)
    #expect(session.textView.undoManager?.canUndo != true)
  }

  @Test func presentationHistoryIsBoundedAndRecordsTheLastStage() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer {
      do { try FileManager.default.removeItem(at: directory) }
      catch { Issue.record(error) }
    }
    let session = DocumentSession(documentID: "bounded", text: "A retained thought")
    let diagnostics = NotebookSourceDiagnostics(fileURL: directory.appending(path: "latest.json"))
    for _ in 0..<50 {
      diagnostics.record(session, mode: .reading, phase: "active", stage: .settled)
    }
    diagnostics.record(session, mode: .source, phase: "background", stage: .settled)
    #expect(diagnostics.snapshots.count == 48)
    #expect(diagnostics.snapshots.last?.stage == "settled")
    #expect(diagnostics.snapshots.last?.scenePhase == "background")
    #expect(diagnostics.snapshots.last?.mode == NoteMode.source.rawValue)
  }

  @Test func repeatedWidthRequestsDoNotWritePerAnimationFrame() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer {
      do { try FileManager.default.removeItem(at: directory) }
      catch { Issue.record(error) }
    }
    let session = DocumentSession(documentID: "resizing", text: "Keep the current passage")
    let diagnostics = NotebookSourceDiagnostics(fileURL: directory.appending(path: "latest.json"))
    for _ in 0..<50 {
      diagnostics.record(session, mode: .reading, phase: "active", stage: .requested)
    }
    #expect(diagnostics.snapshots.count == 1)
    diagnostics.record(session, mode: .source, phase: "active", stage: .requested)
    diagnostics.record(session, mode: .source, phase: "active", stage: .settled)
    #expect(diagnostics.snapshots.count == 3)
    diagnostics.record(session, mode: .source, phase: "active", stage: .disappeared)
    diagnostics.record(session, mode: .source, phase: "active", stage: .requested)
    #expect(diagnostics.snapshots.count == 5)
  }
}
