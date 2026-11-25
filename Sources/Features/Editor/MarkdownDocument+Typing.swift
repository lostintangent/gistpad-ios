import Foundation
import Markdown

extension MarkdownDocument {
    /// What a keystroke means in Markdown: Return continues a list or ends an empty item, brackets
    /// pair, and a URL pasted over text links it. Nil for ordinary input or protected syntax, so the
    /// text view types natively.
    func edit(typing replacement: String, over selection: NSRange) -> MarkdownEdit? {
        if ["\n", "\r", "\r\n"].contains(replacement) {
            guard !isProtected(selection) else { return nil }
            return endingList(at: selection) ?? edit(continuingListAt: selection)
        }
        if let edit = pairingBracket(replacement, over: selection) {
            return isProtected(selection) ? nil : edit
        }
        let selected = (text as NSString).substring(with: selection)
        guard !selected.isEmpty, !selected.allSatisfy(\.isWhitespace),
            replacement.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
            ["http", "https"].contains(URL(string: replacement)?.scheme?.lowercased()),
            !isProtected(selection)
        else { return nil }
        return edit(linking: selection, to: replacement, label: selected)
    }

    /// Return in an item with no text ends the list, leaving its line blank.
    private func endingList(at selection: NSRange) -> MarkdownEdit? {
        guard let item = listItem(at: selection.location), selection.location >= NSMaxRange(item.prefix),
            NSMaxRange(selection) <= NSMaxRange(item.range),
            (text as NSString).substring(with: NSRange(NSMaxRange(item.prefix)..<NSMaxRange(item.range)))
                .allSatisfy(\.isWhitespace)
        else { return nil }
        return edit(replacing: item.range, with: "", selection: NSRange(location: item.range.location, length: 0))
    }

    private static let brackets = [
        (open: "(", close: ")"), (open: "[", close: "]"), (open: "{", close: "}"),
    ]
    private static let closesBefore = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ")]}.,;:!?"))

    /// An opener closes before a space, a line end or a closer, so one typed before a word stays
    /// single. Its closer steps over a waiting one, and backspace in an empty pair deletes both.
    private func pairingBracket(_ replacement: String, over selection: NSRange) -> MarkdownEdit? {
        let source = text as NSString
        let caret = NSMaxRange(selection)
        let next = caret < source.length ? source.substring(with: NSRange(location: caret, length: 1)) : ""
        if replacement.isEmpty, selection.length == 1,
            let pair = Self.brackets.first(where: { $0.open == source.substring(with: selection) }),
            next == pair.close
        {
            return edit(
                replacing: NSRange(location: selection.location, length: 2), with: "",
                selection: NSRange(location: selection.location, length: 0))
        }
        guard selection.length == 0 else { return nil }
        if let pair = Self.brackets.first(where: { $0.open == replacement }),
            next.isEmpty || next.rangeOfCharacter(from: Self.closesBefore) != nil
        {
            return edit(
                replacing: selection, with: pair.open + pair.close,
                selection: NSRange(location: caret + 1, length: 0))
        }
        // When the line already balances its closers, the one after the caret is waiting for this one.
        if let pair = Self.brackets.first(where: { $0.close == replacement }), next == pair.close {
            let line = source.substring(with: source.lineRange(for: selection))
            guard line.count(where: { String($0) == pair.open }) <= line.count(where: { String($0) == pair.close })
            else { return nil }
            return edit(replacing: selection, with: "", selection: NSRange(location: caret + 1, length: 0))
        }
        return nil
    }
}
