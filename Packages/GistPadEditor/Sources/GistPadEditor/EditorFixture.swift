import Foundation

public enum EditorFixture {
  public static func markdown() throws -> String {
    guard let url = Bundle.module.url(forResource: "Editor", withExtension: "md") else {
      throw CocoaError(.fileNoSuchFile)
    }
    let opening = try String(contentsOf: url, encoding: .utf8)
    return opening
      + (1...240).map { index in
        """

        ## Field note \(index)

        A quiet notebook keeps its words through every change of shape. Line \(index) contains **Markdown**, `let note = "unchanged"` and a [reference](https://gistpad.dev).

        日本語の入力を途中で止めても、文章と選択範囲を保ちます。ひらがな、カタカナ、漢字。
        العربية تظل كما كتبتها. עברית נשארת ללא שינוי.
        Emoji: 👨‍👩‍👧‍👦 🧑🏽‍💻 🏳️‍🌈 🇯🇵 cafe\u{301} 📝

        - [ ] Duplicate task
        - [ ] Duplicate task
        - [x] This is a synthetic fixture, not a real gist.

        """
      }.joined()
  }
}
