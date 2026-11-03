import Foundation

public enum FrontMatter {
  public static func contentStart(in text: String) -> Int {
    Syntax.contentStart(in: text)
  }
}
