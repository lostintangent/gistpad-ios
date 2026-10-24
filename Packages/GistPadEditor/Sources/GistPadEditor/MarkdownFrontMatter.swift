import Foundation

public enum MarkdownFrontMatter {
  public static func contentStart(in text: String) -> Int {
    let source = text as NSString
    guard source.length > 0 else { return 0 }
    func line(at offset: Int) -> (text: String, end: Int) {
      var end = 0
      var contentsEnd = 0
      source.getLineStart(
        nil, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: offset, length: 0))
      return (source.substring(with: NSRange(location: offset, length: contentsEnd - offset)), end)
    }
    func isFence(_ value: String) -> Bool {
      value.hasPrefix("---") && value.dropFirst(3).allSatisfy(\.isWhitespace)
    }
    let opening = line(at: 0)
    guard isFence(opening.text) else { return 0 }
    var offset = opening.end
    while offset < source.length {
      let current = line(at: offset)
      if isFence(current.text) {
        guard current.end > offset + current.text.utf16.count else { return 0 }
        var content = current.end
        while content < source.length {
          let next = line(at: content)
          guard next.text.allSatisfy(\.isWhitespace),
            next.end > content + next.text.utf16.count
          else { break }
          content = next.end
        }
        return content
      }
      offset = current.end
    }
    return 0
  }
}
