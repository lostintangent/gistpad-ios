import Foundation
import GistPadIntelligence

@main
@MainActor
struct Evaluate {
  static func main() async throws {
    guard CommandLine.arguments.count == 4,
      let repeats = Int(CommandLine.arguments[3]), repeats > 0
    else { throw NoteIntelligenceError.invalidResponse }
    let cases = try JSONDecoder().decode(
      [NoteEvaluationCase].self, from: Data(contentsOf: URL(filePath: CommandLine.arguments[1])))
    let output = URL(filePath: CommandLine.arguments[2])
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let info = try await AppleNoteModel().modelInfo()
    let heading =
      "Model: \(info.variant)\nContext: \(info.contextSize)\nRepetitions: \(repeats)\n\n"
    print(
      "model=\(info.variant) context=\(info.contextSize) cases=\(cases.count) repeats=\(repeats)")
    var finalResults: [NoteEvaluationResult] = []
    try await NoteIntelligenceEvaluation.run(
      cases: cases, repeats: repeats, retainPrivateOutput: true
    ) { results in
      finalResults = results
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(results).write(
        to: output.appending(path: "results-private.json"), options: .atomic)
      let table = heading + NoteIntelligenceEvaluation.table(results)
      try table.write(to: output.appending(path: "summary.md"), atomically: true, encoding: .utf8)
      if let result = results.last {
        print(
          "\(result.passed ? "PASS" : "FAIL") \(result.caseID) run=\(result.repeatIndex) outcome=\(result.errorCode ?? "success") qualityRetries=\(result.qualityRetryCount ?? 0) qualityRejections=\(result.qualityRejectionCount ?? 0) totalSeconds=\(Int(result.elapsedSeconds)) request=\(result.requestID)"
        )
        fflush(stdout)
      }
    }
    print(try String(contentsOf: output.appending(path: "summary.md"), encoding: .utf8))
    if repeats < 10 {
      print("Smoke run only. Acceptance requires at least 10 repetitions.")
    }
    let meetsFloor = cases.allSatisfy { item in
      let group = finalResults.filter { $0.caseID == item.id }
      return Double(group.filter(\.passed).count) / Double(group.count)
        >= (item.favorite == nil ? 1 : 0.9)
    }
    if !meetsFloor { exit(1) }
  }
}
