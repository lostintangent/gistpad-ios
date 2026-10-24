import Foundation

struct NoteSourceBlock: Encodable {
  let id: Int
  let text: String
  let firstOrderedItem: String?

  init(id: Int, text: String) {
    self.id = id
    self.text = text
    firstOrderedItem =
      text.components(separatedBy: .newlines).compactMap { line in
        guard let marker = line.range(of: #"^[ \t]*[0-9]+[.)][ \t]+"#, options: .regularExpression)
        else {
          return nil
        }
        return String(line[marker.upperBound...])
      }.first
  }

  static func blocks(in source: String) -> [Self] {
    let text = source as NSString
    var offsets = [0]
    var offset = 0
    while offset < text.length {
      let line = text.lineRange(for: NSRange(location: offset, length: 0))
      let value = text.substring(with: line)
      if offset > 0, value.range(of: #"^ {0,3}#{1,6}[ \t]"#, options: .regularExpression) != nil {
        offsets.append(offset)
      }
      offset = NSMaxRange(line)
    }
    offsets.append(text.length)
    return zip(offsets, offsets.dropFirst()).enumerated().compactMap { index, pair in
      guard pair.1 > pair.0 else { return nil }
      return Self(
        id: index + 1,
        text: text.substring(with: NSRange(location: pair.0, length: pair.1 - pair.0)))
    }
  }

  static func quotations(ids: [Int], from blocks: [Self]) throws -> [String] {
    guard Set(ids).count == ids.count,
      ids.allSatisfy({ id in blocks.contains { $0.id == id } })
    else { throw NoteIntelligenceError.unverifiedQuotation }
    return ids.compactMap { id in blocks.first { $0.id == id }?.text }
  }
}
