#if DEBUG
  import GistPadComments
  import GistPadEditor
  import GistPadPreview
  import SwiftUI
  import UIKit

  struct CommentHighlightCaptureWorkspace: View {
    let session: DocumentSession
    @State private var source = ProcessInfo.processInfo.arguments.contains("--capture-source")
    @State private var selectedID: Int64? =
      ProcessInfo.processInfo.arguments.contains("--capture-selected-first-comment") ? 10
      : ProcessInfo.processInfo.arguments.contains("--capture-selected-comment") ? 60 : nil
    @State private var showsInline = true
    @State private var revealRevision: UInt64 = 0
    @State private var linked: Set<Int64> = []
    @State private var renderedGeneration: UInt64?
    @State private var opened: [Int64] = []
    @State private var openCount = 0
    @State private var choosesThread = false
    @State private var selection: QuotedSelection?
    @State private var failure: String?
    @State private var tapPoint: CGPoint?

    static let markdown = """
      # Comment notebook

      🫧 A quiet native note, with **careful** words.

      A café moment to keep. A notebook has room for a surprise.

      `native code` stays code in Preview.

      <details><summary>A tucked thought</summary><p>A tucked native passage to revisit.</p></details>

      A spoiler: >!A secret native passage to reveal.!<

      """
      + Array(
        repeating: "A little room for thoughts, sketches, and the shape of a good day.",
        count: 20
      ).joined(separator: "\n\n")
      + "\n\n## Further down\n\nA late native passage should scroll into view.\n"

    private static let quotes = [
      CommentQuote(commentID: 10, quote: "quiet native"),
      CommentQuote(commentID: 20, quote: "native note"),
      CommentQuote(commentID: 30, quote: "careful"),
      CommentQuote(commentID: 40, quote: "tucked native passage"),
      CommentQuote(commentID: 50, quote: "secret native passage"),
      CommentQuote(commentID: 60, quote: "late native passage"),
      CommentQuote(commentID: 70, quote: "native code"),
      CommentQuote(commentID: 80, quote: "café moment"),
      CommentQuote(commentID: 90, quote: "notebook"),
      CommentQuote(commentID: 100, quote: "unwritten"),
    ]

    private var configuration: CommentHighlightConfiguration {
      .init(
        quotes: Self.quotes, selectedCommentID: selectedID,
        revealRevision: revealRevision, showsInlineComments: showsInline)
    }

    private var expectedIDs: Set<Int64> {
      Set(Self.quotes.map(\.commentID)).subtracting(source ? [90, 100] : [70, 90, 100])
    }

    private var status: String {
      let ready = linked == expectedIDs && (source || renderedGeneration == session.generation)
      let point = tapPoint.map { "\(Int($0.x.rounded())),\(Int($0.y.rounded()))" } ?? "none"
      return "ready:\(ready ? 1 : 0)|mode:\(source ? "edit" : "preview")"
        + "|linked:\(linked.sorted().map(String.init).joined(separator: ","))"
        + "|selected:\(selectedID.map(String.init) ?? "none")"
        + "|opened:\(opened.map(String.init).joined(separator: ","))|opens:\(openCount)|tap:\(point)"
        + "|generation:\(session.generation)"
    }

    var body: some View {
      NavigationStack {
        Group {
          if source {
            MarkdownEditorView(
              session: session, comments: configuration,
              onOpenCommentThreads: open,
              onLinkedCommentIDsChange: { if source { linked = $0 } },
              onAddComment: add)
          } else {
            MarkdownPreviewView(
              document: session.text, documentID: session.documentID,
              generation: session.generation, allowsTaskEdits: false,
              comments: configuration, onOpenCommentThreads: open,
              onLinkedCommentIDsChange: { if !source { linked = $0 } },
              onAddComment: add
            ) { event in
              switch event {
              case .rendered(_, let generation): renderedGeneration = generation
              case .failure(let error): failure = error.localizedDescription
              default: break
              }
            }
          }
        }
        .navigationTitle("Comment Notebook")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .principal) {
            Picker("Mode", selection: $source) {
              Text("Edit").tag(true)
              Text("Preview").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .accessibilityIdentifier("comment-capture-mode")
          }
          ToolbarItem(placement: .primaryAction) {
            Menu("Passages", systemImage: "text.bubble") {
              Button("First Passage") { selectPassage(10) }
              Button("Tucked Passage") { selectPassage(40) }
              Button("Secret Passage") { selectPassage(50) }
              Button("Last Passage") { selectPassage(60) }
              Button("Clear Selection") { selectedID = nil }
              Toggle("Inline Comments", isOn: $showsInline)
              if source {
                Button("Locate Source Passage") { locateSourcePassage() }
                Button("Locate Selected Passage") { locateSourcePassage(commentID: selectedID) }
              }
            }
            .accessibilityIdentifier("comment-capture-passages")
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          Text(status)
            .font(.caption2.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.bar)
            .accessibilityIdentifier("comment-capture-status")
        }
        .confirmationDialog("Choose Comment", isPresented: $choosesThread) {
          ForEach(opened, id: \.self) { id in
            Button("Thread \(id)") { selectedID = id }
          }
        }
        .sheet(item: $selection) { quote in
          NavigationStack {
            ScrollView {
              Text(quote.value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .accessibilityIdentifier("comment-capture-quote")
            }
            .navigationTitle("Selected Quote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") { selection = nil }
              }
            }
          }
        }
        .alert(
          "Preview Unavailable",
          isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
          )
        ) {
          Button("OK") { failure = nil }
        } message: {
          Text(failure ?? "")
        }
        .onChange(of: source) { _, _ in
          linked = []
          tapPoint = nil
          renderedGeneration = nil
        }
      }
      .background {
        MarkerCaptureContrast(
          increased: ProcessInfo.processInfo.arguments.contains("--capture-increased-contrast")
        )
        .frame(width: 0, height: 0)
      }
    }

    private func open(_ ids: [Int64]) {
      openCount += 1
      opened = ids
      if ids.count == 1 { selectedID = ids.first } else { choosesThread = true }
    }

    private func selectPassage(_ id: Int64) {
      selectedID = id
      revealRevision &+= 1
    }

    private func add(_ quote: String) {
      session.textView.resignFirstResponder()
      selection = QuotedSelection(value: quote)
    }

    private func locateSourcePassage(commentID: Int64? = nil) {
      let view = session.textView
      guard let window = view.window,
        let highlight = CommentQuoteMatcher.highlights(
          quotes: Self.quotes, segments: [session.text]
        ).first(where: {
          commentID.map($0.commentIDs.contains) ?? ($0.commentIDs == [10, 20])
        }),
        let start = view.position(from: view.beginningOfDocument, offset: highlight.start),
        let end = view.position(from: view.beginningOfDocument, offset: highlight.end),
        let range = view.textRange(from: start, to: end)
      else {
        failure = "The source passage could not be located."
        return
      }
      view.layoutIfNeeded()
      let frame = view.convert(view.firstRect(for: range), to: window)
      guard !frame.isEmpty, !frame.isInfinite, !frame.isNull else {
        failure = "The source passage has no laid-out text frame."
        return
      }
      tapPoint = CGPoint(x: frame.midX, y: frame.midY)
    }

    private struct QuotedSelection: Identifiable {
      let id = UUID()
      let value: String
    }
  }
#endif
