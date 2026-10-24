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
        try AppleNoteModel.decodeAnswer(
          GeneratedContent(json: #"{"blockIDs":[],"answer":" \n\t"}"#))
      }
      let parts = try AppleNoteModel.decodeAnswer(
        GeneratedContent(json: #"{"blockIDs":[],"answer":"Two series are in progress."}"#))
      #expect(parts == [ModelAnswerPart(kind: .prose, text: "Two series are in progress.")])
    }

    @Test func allTasksAndSpecificTaskStatesDecodeFromTheActualGeneratedSchema() throws {
      let content = try GeneratedContent(
        json: """
          {"taskChanges":[
            {"target":"all","ids":[],"isComplete":true},
            {"target":"specific","ids":[1,2],"isComplete":false}
          ],"newTasks":[],"deleteTaskIDs":[],"textChanges":[]}
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

    @Test func explicitAllScopeDoesNotFailBecauseOfRedundantIDs() throws {
      let operations = try AppleNoteModel.decodeEditPlan(
        GeneratedContent(
          json: """
            {"taskChanges":[{"target":"all","ids":[1],"isComplete":false}],
             "newTasks":[],"deleteTaskIDs":[],"textChanges":[]}
            """))
      guard case .setTaskStates(let ids, let complete) = operations.first else {
        Issue.record("Expected an all-task operation")
        return
      }
      #expect(ids == nil)
      #expect(!complete)
    }

    @Test func insertionAndDeletionHaveTheirOwnGeneratedOperations() throws {
      let operations = try AppleNoteModel.decodeEditPlan(
        GeneratedContent(
          json: """
            {"taskChanges":[],"newTasks":[{"text":"Clean the sink","listID":2}],
             "deleteTaskIDs":[3],"textChanges":[]}
            """))
      #expect(operations.count == 2)
      guard case .insertTask(let list, let text) = operations[0],
        case .deleteTasks(let ids) = operations[1]
      else {
        Issue.record("Expected insert and delete task operations")
        return
      }
      #expect(list == 2)
      #expect(text == "Clean the sink")
      #expect(ids == [3])
    }

    @Test func selectedBlockCitationsUseOriginalEvidenceBytesNotSynthesisSeparators() throws {
      let original = "# One\r\n\r\nFirst 👩🏽‍💻\r\n\r\n# Two\n\nSecond cafe\u{301}\n"
      let blocks = NoteSourceBlock.blocks(in: original)
      #expect(blocks.map(\.text).joined().utf8.elementsEqual(original.utf8))
      let parts = try AppleNoteModel.decodeAnswer(
        GeneratedContent(json: #"{"blockIDs":[2],"answer":"The second section answers."}"#),
        blocks: blocks)
      #expect(parts.last == ModelAnswerPart(kind: .quote, text: blocks[1].text))
      #expect(throws: NoteIntelligenceError.unverifiedQuotation) {
        try AppleNoteModel.decodeAnswer(
          GeneratedContent(json: #"{"blockIDs":[99],"answer":"An answer"}"#), blocks: blocks)
      }
    }
  }
#endif
