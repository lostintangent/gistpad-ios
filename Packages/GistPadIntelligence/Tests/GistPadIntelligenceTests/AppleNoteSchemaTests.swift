#if canImport(FoundationModels) && os(iOS)
  import FoundationModels
  import Testing

  @testable import GistPadIntelligence

  @MainActor
  struct AppleNoteSchemaTests {
    @Test func answerSchemaRequiresTheAnswerFieldRatherThanAnOptionalEmptyArray() throws {
      #expect(throws: (any Error).self) {
        try AppleNoteModel.decodeAnswer(GeneratedContent(json: #"{"parts":[]}"#))
      }
      #expect(throws: NoteIntelligenceError.emptyAnswer) {
        try AppleNoteModel.decodeAnswer(GeneratedContent(json: #"{"answer":" \n\t","quotes":[]}"#))
      }
      let parts = try AppleNoteModel.decodeAnswer(
        GeneratedContent(json: #"{"answer":"Two series are in progress.","quotes":[]}"#))
      #expect(parts == [ModelAnswerPart(kind: .prose, text: "Two series are in progress.")])
    }

    @Test func allTasksAndSpecificTaskStatesDecodeFromTheActualGeneratedSchema() throws {
      let content = try GeneratedContent(
        json: """
          {"taskChanges":[
            {"target":"all","ids":[],"isComplete":true},
            {"target":"specific","ids":[1,2],"isComplete":false}
          ],"textChanges":[]}
          """)
      let operations = try AppleNoteModel.decodeEditPlan(content)
      #expect(operations.count == 2)
      guard case .setTaskStates(let all, let complete) = operations[0],
        case .setTaskStates(let ids, let incomplete) = operations[1]
      else {
        Issue.record("Expected typed task-state operations")
        return
      }
      #expect(all == nil)
      #expect(complete)
      #expect(ids == [1, 2])
      #expect(!incomplete)
    }

    @Test func anAmbiguousAllTasksTargetCannotSilentlyOverrideSpecificIDs() {
      #expect(throws: NoteIntelligenceError.invalidResponse) {
        try AppleNoteModel.decodeEditPlan(
          GeneratedContent(
            json: """
              {"taskChanges":[{"target":"all","ids":[1],"isComplete":true}],"textChanges":[]}
              """))
      }
    }
  }
#endif
