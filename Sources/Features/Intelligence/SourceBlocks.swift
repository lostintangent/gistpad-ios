import Foundation
import Editor

struct SourceBlock: Encodable {
  let id: Int
  let text: String

  init(id: Int, text: String) {
    self.id = id
    self.text = text
  }

  static func blocks(in source: String) -> [Self] {
    let text = source as NSString
    let offsets = [0] + Syntax.outline(in: source).blocks
      .filter { $0.kind == .heading && $0.range.location > 0 }
      .map(\.range.location) + [text.length]
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
    else { throw IntelligenceError.unverifiedQuotation }
    return ids.compactMap { id in blocks.first { $0.id == id }?.text }
  }
}
