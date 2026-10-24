import Foundation
import GistPadEditor
import OSLog

enum NotebookExcerpt {
  private struct Block {
    let identity: Int
    let headingLevel: Int?
    let isListItem: Bool
    var text: String
  }

  static func text(from source: String, title: String? = nil) -> String? {
    let contentStart = MarkdownFrontMatter.contentStart(in: source)
    if contentStart == 0,
      source.prefix(while: { !$0.isNewline }).trimmingCharacters(in: .whitespaces) == "---"
    {
      return nil
    }
    do {
      let markdown = (source as NSString).substring(from: contentStart)
      let parsed = try AttributedString(markdown: markdown)
      var blocks: [Block] = []
      for run in parsed.runs {
        let inline = run.inlinePresentationIntent ?? []
        guard !inline.contains(.inlineHTML), !inline.contains(.blockHTML),
          let components = run.presentationIntent?.components,
          let component = components.first
        else { continue }
        guard !components.contains(where: {
          switch $0.kind {
          case .codeBlock, .thematicBreak: true
          default: false
          }
        }) else { continue }
        let text = inline.contains(.softBreak)
          ? "\n" : String(parsed[run.range].characters)
        if blocks.last?.identity == component.identity {
          blocks[blocks.count - 1].text += text
        } else {
          blocks.append(Block(
            identity: component.identity,
            headingLevel: components.lazy.compactMap {
              if case .header(let level) = $0.kind { level } else { nil }
            }.first,
            isListItem: components.contains { if case .listItem = $0.kind { true } else { false } },
            text: text))
        }
      }
      let lines = blocks.enumerated().compactMap { index, block -> String? in
        if index == 0, let level = block.headingLevel {
          let heading = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
          let matchesTitle = title.map {
            heading.compare($0.trimmingCharacters(in: .whitespacesAndNewlines),
              options: .caseInsensitive) == .orderedSame
          } ?? false
          let isDateHeader = heading.range(
            of: #"^[^\p{L}\p{N}]*[0-9]{4}[-/:][0-9]{1,2}[-/:][0-9]{1,2}$"#,
            options: .regularExpression) != nil
          if level == 1 || matchesTitle || isDateHeader { return nil }
        }
        var text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if block.isListItem,
          ["[ ]", "[x]", "[X]"].contains(String(text.prefix(3))),
          text.count == 3 || text.dropFirst(3).first?.isWhitespace == true
        {
          text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
      }
      return lines.isEmpty ? nil : lines.joined(separator: "\n")
    } catch {
      let error = error as NSError
      Logger(subsystem: "dev.gistpad.GistPad", category: "Library")
        .error("Couldn't extract a cached excerpt: \(error.domain, privacy: .public) \(error.code)")
      return nil
    }
  }
}
