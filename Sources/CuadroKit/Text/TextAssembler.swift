import CoreGraphics
import Foundation

/// A recognized piece of text and its box in y-down image coordinates.
public struct TextFragment: Equatable, Sendable {
    public var text: String
    public var box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

/// Rebuilds reading order from OCR fragments.
public enum TextAssembler {
    /// Groups fragments into lines by vertical overlap, orders them left to right, joins with
    /// single spaces and separates paragraphs (large vertical gaps) with a blank line.
    public static func assemble(_ fragments: [TextFragment]) -> String {
        let items = fragments
            .map { TextFragment(text: collapseSpaces($0.text), box: $0.box) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.box.midY < $1.box.midY }
        guard !items.isEmpty else { return "" }

        var lines: [(box: CGRect, parts: [TextFragment])] = []
        for item in items {
            if let index = lines.indices.last, overlapsVertically(lines[index].box, item.box) {
                lines[index].box = lines[index].box.union(item.box)
                lines[index].parts.append(item)
            } else {
                lines.append((item.box, [item]))
            }
        }

        let heights = lines.map(\.box.height).sorted()
        let typicalHeight = heights[heights.count / 2]
        var output: [String] = []
        for (index, line) in lines.enumerated() {
            if index > 0 {
                let gap = line.box.minY - lines[index - 1].box.maxY
                if gap > typicalHeight * 1.2 { output.append("") }
            }
            let text = line.parts
                .sorted { $0.box.minX < $1.box.minX }
                .map(\.text)
                .joined(separator: " ")
            output.append(collapseSpaces(text))
        }
        return output.joined(separator: "\n")
    }

    static func overlapsVertically(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap >= 0.5 * min(a.height, b.height)
    }

    static func collapseSpaces(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result
    }
}
