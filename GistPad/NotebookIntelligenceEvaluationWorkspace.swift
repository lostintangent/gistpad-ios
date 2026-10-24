#if DEBUG
  import GistPadEditor
  import GistPadIntelligence
  import SwiftUI

  struct NotebookIntelligenceEvaluationWorkspace: View {
    @State private var status = "Preparing on-device evaluations"
    @State private var table = ""
    @State private var started = false

    var body: some View {
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text(status).font(.headline)
            Text(table).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
        }
        .navigationTitle("Intelligence Evals")
      }
      .task {
        guard !started else { return }
        started = true
        let directory = URL.applicationSupportDirectory.appending(
          path: "IntelligenceEval", directoryHint: .isDirectory)
        do {
          let arguments = ProcessInfo.processInfo.arguments
          let index = arguments.firstIndex(of: "--intelligence-eval-repeats")
          let repeats: Int
          if let index {
            guard arguments.indices.contains(index + 1),
              let count = Int(arguments[index + 1]), count > 0
            else { throw NoteIntelligenceError.invalidResponse }
            repeats = count
          } else {
            repeats = 10
          }
          let cases = try JSONDecoder().decode(
            [NoteEvaluationCase].self,
            from: Data(contentsOf: directory.appending(path: "cases.json")))
          let info = try await AppleNoteModel().modelInfo()
          status =
            "\(info.variant), \(info.contextSize) context. Running \(cases.count) × \(repeats)."
          try await NoteIntelligenceEvaluation.run(cases: cases, repeats: repeats) { results in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(
              to: directory.appending(path: "results.json"), options: .atomic)
            table =
              "Model: \(info.variant)\nContext: \(info.contextSize)\nRepetitions: \(repeats)\n\n"
              + NoteIntelligenceEvaluation.table(results)
            try table.write(
              to: directory.appending(path: "summary.md"), atomically: true, encoding: .utf8)
            status = "\(info.variant): \(results.count)/\(cases.count * repeats) complete"
          }
          status = "\(info.variant): evaluation finished"
        } catch {
          status = error.localizedDescription
          do {
            try FileManager.default.createDirectory(
              at: directory, withIntermediateDirectories: true)
            let errorType = String(reflecting: type(of: error))
            let code = (error as? NoteIntelligenceError)?.diagnosticCode ?? "runnerFailure"
            try "\(code)\n\(errorType)\n".write(
              to: directory.appending(path: "runner-error.txt"), atomically: true, encoding: .utf8)
          } catch {
            status = "Evaluation and result persistence failed. \(error.localizedDescription)"
          }
        }
      }
    }
  }
#endif
