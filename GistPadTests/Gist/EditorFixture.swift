enum EditorFixture {
  static let markdown =
    """
    ---
    title: A notebook that keeps its place
    tags: [phase-zero, synthetic]
    ---

    # A notebook that keeps its place

    This is a **synthetic editor fixture**. Nothing here comes from your GitHub account. There is no network connection or cloud save in this spike.

    ## Try a change of shape

    Place the cursor in the Japanese line. Start composing, then fold or unfold. Return to Library, enter Focus, and undo an edit.

    日本語の入力を続ける。今日は静かなノートを書きます。
    English and العربية and עברית can share one line.
    Family 👨‍👩‍👧‍👦, programmer 🧑🏽‍💻, flag 🇯🇵, combined accent café.

    - [ ] Duplicate task
    - [ ] Duplicate task
    - [x] Keep the same source editor and undo history

    ```swift
    let notebook = "Markdown is the source of truth"
    // Writing Tools should leave this code alone.
    ```

    > [!NOTE]
    > The diagnostic footer shows the lifetime identity of the actual UITextView.

    """
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
