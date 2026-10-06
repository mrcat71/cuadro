import CoreGraphics
import Testing
@testable import CuadroKit

/// Deterministic generator so every synthetic page row is unique.
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct SyntheticPage {
    static let width = 64
    let rows: [[UInt8]]

    init(height: Int, seed: UInt64) {
        var rng = SplitMix64(state: seed)
        rows = (0..<height).map { _ in
            (0..<Self.width).flatMap { _ -> [UInt8] in
                let value = rng.next()
                return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), 255]
            }
        }
    }

    static func solidRow(_ value: UInt8) -> [UInt8] {
        Array(repeating: [value, value / 2, 255 - value, 255], count: width).flatMap { $0 }
    }

    /// Viewport of `height` rows showing the page from `offset`, with optional sticky bars and a
    /// noisy column band (like an overlay scrollbar).
    func frame(offset: Int, height: Int, header: Int = 0, footer: Int = 0, noiseSeed: UInt64? = nil) -> StitchFrame {
        var output: [[UInt8]] = []
        for index in 0..<header { output.append(Self.headerRow(index)) }
        let content = height - header - footer
        for index in 0..<content { output.append(rows[offset + index]) }
        for index in 0..<footer { output.append(Self.footerRow(index)) }
        if let noiseSeed {
            var rng = SplitMix64(state: noiseSeed)
            for row in output.indices {
                for x in 56..<Self.width {
                    output[row][x * 4] = UInt8(rng.next() & 0xFF)
                }
            }
        }
        return StitchFrame(width: Self.width, height: height, pixels: output.flatMap { $0 })
    }

    static func headerRow(_ index: Int) -> [UInt8] {
        (0..<width).flatMap { x in [UInt8(x * 3 % 256), UInt8(index * 7 % 256), 40, 255] }
    }

    static func footerRow(_ index: Int) -> [UInt8] {
        (0..<width).flatMap { x in [200, UInt8(x * 5 % 256), UInt8(index * 11 % 256), 255] }
    }

    func bytes(_ range: Range<Int>) -> [UInt8] { rows[range].flatMap { $0 } }
}

struct ScrollStitcherTests {
    let page = SyntheticPage(height: 800, seed: 42)

    @Test func stitchesPlainScrolling() {
        let stitcher = ScrollStitcher(maxHeight: 10_000)
        let outcomes = [0, 40, 95, 150, 230].map { stitcher.add(page.frame(offset: $0, height: 160)) }
        #expect(outcomes == [.started, .appended(rows: 40), .appended(rows: 55), .appended(rows: 55), .appended(rows: 80)])
        #expect(stitcher.height == 390)
        #expect(stitcher.outputBytes == page.bytes(0..<390))
    }

    @Test func keepsStickyHeaderAndFooterOnce() {
        let stitcher = ScrollStitcher()
        for offset in [0, 30, 70] {
            _ = stitcher.add(page.frame(offset: offset, height: 160, header: 20, footer: 12))
        }
        let header = (0..<20).flatMap { SyntheticPage.headerRow($0) }
        let footer = (0..<12).flatMap { SyntheticPage.footerRow($0) }
        #expect(stitcher.height == 20 + 70 + 128 + 12)
        #expect(stitcher.outputBytes == header + page.bytes(0..<198) + footer)
    }

    @Test func toleratesNoisyScrollbarColumns() {
        let stitcher = ScrollStitcher()
        let outcomes = [0, 50, 100].enumerated().map { index, offset in
            stitcher.add(page.frame(offset: offset, height: 160, noiseSeed: UInt64(index + 1)))
        }
        #expect(outcomes == [.started, .appended(rows: 50), .appended(rows: 50)])
        #expect(stitcher.height == 260)
        // Columns outside the noisy band match the page exactly.
        let bytes = stitcher.outputBytes
        for row in [0, 130, 259] {
            let start = row * SyntheticPage.width * 4
            #expect(Array(bytes[start..<(start + 56 * 4)]) == Array(page.rows[row][0..<(56 * 4)]))
        }
    }

    @Test func ignoresUnchangedAndBackwardFrames() {
        let stitcher = ScrollStitcher()
        #expect(stitcher.add(page.frame(offset: 0, height: 160)) == .started)
        #expect(stitcher.add(page.frame(offset: 0, height: 160)) == .unchanged)
        #expect(stitcher.add(page.frame(offset: 100, height: 160)) == .appended(rows: 100))
        #expect(stitcher.add(page.frame(offset: 60, height: 160)) == .scrolledBack)
        #expect(stitcher.height == 260)
        // Scrolling forward again continues from the last accepted frame.
        #expect(stitcher.add(page.frame(offset: 130, height: 160)) == .appended(rows: 30))
        #expect(stitcher.outputBytes == page.bytes(0..<290))
    }

    @Test func reportsLostTrackWithoutOverlap() {
        let stitcher = ScrollStitcher()
        _ = stitcher.add(page.frame(offset: 0, height: 160))
        #expect(stitcher.add(page.frame(offset: 300, height: 160)) == .lostTrack)
        #expect(stitcher.height == 160)
    }

    @Test func stopsAtMaximumHeight() {
        let stitcher = ScrollStitcher(maxHeight: 250)
        #expect(stitcher.add(page.frame(offset: 0, height: 160)) == .started)
        #expect(stitcher.add(page.frame(offset: 60, height: 160)) == .appended(rows: 60))
        #expect(stitcher.add(page.frame(offset: 120, height: 160)) == .limitReached)
        #expect(stitcher.height == 250)
        #expect(stitcher.add(page.frame(offset: 140, height: 160)) == .limitReached)
        #expect(stitcher.outputBytes == page.bytes(0..<250))
    }

    @Test func rejectsFramesOfDifferentSize() {
        let stitcher = ScrollStitcher()
        _ = stitcher.add(page.frame(offset: 0, height: 160))
        #expect(stitcher.add(page.frame(offset: 10, height: 120)) == .sizeMismatch)
    }

    @Test func buildsImages() throws {
        let stitcher = ScrollStitcher()
        _ = stitcher.add(page.frame(offset: 0, height: 160))
        _ = stitcher.add(page.frame(offset: 80, height: 160))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let image = try #require(stitcher.makeImage(colorSpace: space, bitmapInfo: info))
        #expect(image.width == 64)
        #expect(image.height == 240)
        let preview = try #require(stitcher.previewImage(maxWidth: 16, colorSpace: space, bitmapInfo: info))
        #expect(preview.width == 16)
        #expect(preview.height == 60)
    }
}
