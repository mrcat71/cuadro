import Foundation

/// The run of similar pixels around a point, horizontally and vertically (inclusive bounds).
public struct EdgeSpan: Equatable, Sendable {
    public var minX: Int
    public var maxX: Int
    public var minY: Int
    public var maxY: Int

    public init(minX: Int, maxX: Int, minY: Int, maxY: Int) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
    }

    public var width: Int { maxX - minX + 1 }
    public var height: Int { maxY - minY + 1 }
}

/// Finds where the color changes around a point, for the screen ruler.
public enum EdgeFinder {
    /// Walks left, right, up and down from (`x`, `y`) while pixels stay within `tolerance`
    /// (0...255 per channel) of the starting pixel.
    public static func span(in buffer: PixelBuffer, x: Int, y: Int, tolerance: Int) -> EdgeSpan? {
        guard buffer.contains(x: x, y: y) else { return nil }
        let reference = buffer.rgba(x: x, y: y)
        func matches(_ px: Int, _ py: Int) -> Bool {
            !differs(buffer.rgba(x: px, y: py), reference, tolerance: tolerance)
        }
        var minX = x
        while minX > 0, matches(minX - 1, y) { minX -= 1 }
        var maxX = x
        while maxX < buffer.width - 1, matches(maxX + 1, y) { maxX += 1 }
        var minY = y
        while minY > 0, matches(x, minY - 1) { minY -= 1 }
        var maxY = y
        while maxY < buffer.height - 1, matches(x, maxY + 1) { maxY += 1 }
        return EdgeSpan(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    @inline(__always)
    static func differs(_ a: (UInt8, UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8, UInt8), tolerance: Int) -> Bool {
        abs(Int(a.0) - Int(b.0)) > tolerance
            || abs(Int(a.1) - Int(b.1)) > tolerance
            || abs(Int(a.2) - Int(b.2)) > tolerance
            || abs(Int(a.3) - Int(b.3)) > tolerance
    }
}
