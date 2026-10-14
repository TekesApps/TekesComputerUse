import Foundation

enum TextSelectionResolver {
  static func range(
    in fullText: String,
    matching needle: String,
    prefix: String? = nil,
    suffix: String? = nil
  ) throws -> NSRange {
    let candidates = fullText.ranges(of: needle).filter { range in
      let before = String(fullText[..<range.lowerBound])
      let after = String(fullText[range.upperBound...])
      return (prefix == nil || before.hasSuffix(prefix!))
        && (suffix == nil || after.hasPrefix(suffix!))
    }
    guard candidates.count == 1, let range = candidates.first else {
      throw ToolError(
        candidates.isEmpty ? "text not found" : "text is ambiguous; provide prefix or suffix")
    }
    return NSRange(range, in: fullText)
  }
}
extension String {
  fileprivate func ranges(of needle: String) -> [Range<String.Index>] {
    guard !needle.isEmpty else { return [] }
    var ranges: [Range<String.Index>] = []
    var searchStart = startIndex
    while searchStart < endIndex,
      let range = range(of: needle, range: searchStart..<endIndex)
    {
      ranges.append(range)
      searchStart = range.upperBound
    }
    return ranges
  }
}
