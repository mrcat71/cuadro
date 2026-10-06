import CoreGraphics
import Testing
@testable import CuadroKit

struct ImagingTests {
    /// 20x10 white image with a black 4x3 block at (5, 2).
    static func sample() -> PixelBuffer {
        var buffer = PixelBuffer(width: 20, height: 10, fill: .white)
        buffer.fill(PixelRect(x: 5, y: 2, width: 4, height: 3), with: .black)
        return buffer
    }

    @Test(arguments: [
        ((1, 1), EdgeSpan(minX: 0, maxX: 19, minY: 0, maxY: 9)),
        ((6, 3), EdgeSpan(minX: 5, maxX: 8, minY: 2, maxY: 4)),
        ((2, 3), EdgeSpan(minX: 0, maxX: 4, minY: 0, maxY: 9)),
        ((6, 8), EdgeSpan(minX: 0, maxX: 19, minY: 5, maxY: 9)),
    ])
    func edgeSpans(point: (Int, Int), expected: EdgeSpan) {
        #expect(EdgeFinder.span(in: Self.sample(), x: point.0, y: point.1, tolerance: 0) == expected)
    }

    @Test func edgeSpanOutsideImageIsNil() {
        #expect(EdgeFinder.span(in: Self.sample(), x: 25, y: 1, tolerance: 0) == nil)
    }

    @Test func toleranceMergesSimilarColors() {
        var buffer = PixelBuffer(width: 10, height: 1, fill: RGBAColor(red8: 100, green8: 100, blue8: 100))
        buffer.setColor(RGBAColor(red8: 104, green8: 100, blue8: 100), x: 6, y: 0)
        #expect(EdgeFinder.span(in: buffer, x: 0, y: 0, tolerance: 0)?.maxX == 5)
        #expect(EdgeFinder.span(in: buffer, x: 0, y: 0, tolerance: 5)?.maxX == 9)
    }

    @Test func averageAndDominantColors() {
        let buffer = Self.sample()
        #expect(buffer.averageColor(in: PixelRect(x: 5, y: 2, width: 4, height: 3)) == .black)
        let mixed = buffer.averageColor(in: PixelRect(x: 4, y: 2, width: 2, height: 1))
        #expect(mixed.map { abs($0.red - 0.5) < 0.01 } == true)
        #expect(buffer.dominantSurroundingColor(of: PixelRect(x: 5, y: 2, width: 4, height: 3)) == .white)
        // At the image edge the ring falls back to inside pixels.
        #expect(buffer.dominantSurroundingColor(of: PixelRect(x: 0, y: 0, width: 3, height: 3)) == .white)
    }

    @Test func trimsUniformBorders() {
        let buffer = Self.sample()
        let full = PixelRect(x: 0, y: 0, width: 20, height: 10)
        #expect(buffer.trimmedContentRect(full) == PixelRect(x: 5, y: 2, width: 4, height: 3))
        let blank = PixelBuffer(width: 8, height: 8, fill: .white)
        #expect(blank.trimmedContentRect(PixelRect(x: 0, y: 0, width: 8, height: 8)) == PixelRect(x: 0, y: 0, width: 8, height: 8))
    }

    @Test(arguments: [
        ([PixelRect(x: 3, y: 2, width: 4, height: 5)], PixelRect(x: 3, y: 2, width: 4, height: 5)),
        ([PixelRect(x: 1, y: 1, width: 1, height: 1), PixelRect(x: 10, y: 6, width: 2, height: 3)], PixelRect(x: 1, y: 1, width: 11, height: 8)),
        ([PixelRect(x: 0, y: 0, width: 16, height: 12)], PixelRect(x: 0, y: 0, width: 16, height: 12)),
    ])
    func visibleBoundsCoverNonTransparentPixels(blocks: [PixelRect], expected: PixelRect) {
        var buffer = PixelBuffer(width: 16, height: 12, fill: .clear)
        for block in blocks {
            buffer.fill(block, with: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.1))
        }
        #expect(buffer.visibleBounds() == expected)
    }

    @Test func visibleBoundsOfTransparentImageIsNil() {
        #expect(PixelBuffer(width: 8, height: 8, fill: .clear).visibleBounds() == nil)
    }

    @Test func roundTripsThroughCGImage() throws {
        let buffer = Self.sample()
        let image = try #require(buffer.makeImage())
        let copy = try #require(PixelBuffer(image: image))
        #expect(copy.bytes == buffer.bytes)
        let region = try #require(PixelBuffer(image: image, region: PixelRect(x: 4, y: 1, width: 3, height: 3)))
        #expect(region.width == 3)
        #expect(region.color(x: 0, y: 0) == .white)
        #expect(region.color(x: 1, y: 1) == .black)
    }

    @Test func pixelRectCoversFractionalRects() {
        #expect(PixelRect(covering: CGRect(x: 1.5, y: 2.2, width: 3, height: 1.1)) == PixelRect(x: 1, y: 2, width: 4, height: 2))
        #expect(PixelRect(x: -2, y: 3, width: 10, height: 10).clamped(width: 5, height: 5) == PixelRect(x: 0, y: 3, width: 5, height: 2))
    }
}
