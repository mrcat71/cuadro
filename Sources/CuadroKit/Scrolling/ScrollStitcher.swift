import CoreGraphics
import Foundation

/// One captured frame of the scrolling region: 4 bytes per pixel (BGRA or RGBA), rows top to bottom.
public struct StitchFrame: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4, "StitchFrame byte count mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

public enum StitchOutcome: Equatable, Sendable {
    /// First frame stored.
    case started
    /// New content appended; `rows` is the detected scroll distance in pixels.
    case appended(rows: Int)
    /// Nothing scrolled (or only small animations changed).
    case unchanged
    /// The content moved down (the user scrolled back up); the frame is ignored.
    case scrolledBack
    /// No overlap with the previous frame was found (scrolled too fast or content changed).
    case lostTrack
    /// The maximum height was reached; no more rows are accepted.
    case limitReached
    /// The frame size differs from the first frame.
    case sizeMismatch
}

/// Stitches vertically scrolled frames into one tall image.
///
/// Each row is fingerprinted as several column segments so a changing overlay scrollbar or a
/// small animation does not break matching. The scroll offset is found by voting over
/// segment-hash matches between the previous accepted frame and the new one; sticky headers
/// and footers are detected as rows that stay identical at the same position.
public final class ScrollStitcher {
    public let maxHeight: Int
    public let segmentCount: Int
    public private(set) var width = 0
    public private(set) var frameHeight = 0
    public private(set) var height = 0
    public private(set) var isFull = false

    private var output: [UInt8] = []
    private var reference: Signature?

    public init(maxHeight: Int = 20_000, segmentCount: Int = 8) {
        self.maxHeight = max(1, maxHeight)
        self.segmentCount = max(1, segmentCount)
    }

    public var isEmpty: Bool { height == 0 }

    /// The stitched bytes so far (`height` rows of `width * 4` bytes).
    public var outputBytes: [UInt8] { output }

    public func add(_ frame: StitchFrame) -> StitchOutcome {
        if isFull { return .limitReached }
        let signature = Signature(frame: frame, segments: segmentCount)
        guard let reference else {
            width = frame.width
            frameHeight = frame.height
            let rows = min(frame.height, maxHeight)
            output = Array(frame.pixels[0..<(rows * frame.width * 4)])
            height = rows
            self.reference = signature
            if rows < frame.height {
                isFull = true
                return .limitReached
            }
            return .started
        }
        guard frame.width == width, frame.height == frameHeight else { return .sizeMismatch }
        let rows = frameHeight

        // Unchanged frame: almost every informative row is identical at the same position.
        var informative = 0
        var same = 0
        for row in 0..<rows where signature.informativeRows[row] || reference.informativeRows[row] {
            informative += 1
            if Signature.similar(reference, row, signature, row) { same += 1 }
        }
        if informative == 0 || Double(same) >= 0.97 * Double(informative) { return .unchanged }

        // Sticky header and footer rows stay put while the content between them scrolls.
        var top = 0
        while top < rows, Signature.similar(reference, top, signature, top) { top += 1 }
        var bottom = 0
        while bottom < rows - top, Signature.similar(reference, rows - 1 - bottom, signature, rows - 1 - bottom) {
            bottom += 1
        }
        let lower = top
        let upper = rows - bottom
        guard upper - lower >= 4 else { return .unchanged }

        guard let offset = Self.bestOffset(reference: reference, current: signature, lower: lower, upper: upper) else {
            return .lostTrack
        }
        if offset == 0 { return .unchanged }
        if offset < 0 { return .scrolledBack }

        var compared = 0
        var matched = 0
        for row in lower..<(upper - offset) where signature.informativeRows[row] || reference.informativeRows[row + offset] {
            compared += 1
            if Signature.similar(reference, row + offset, signature, row) { matched += 1 }
        }
        guard compared >= 2, Double(matched) >= 0.6 * Double(compared) else { return .lostTrack }

        // The output always ends with the reference frame's footer: drop it, then append the new
        // content plus the new footer.
        let rowBytes = width * 4
        output.removeLast(bottom * rowBytes)
        height -= bottom
        let appendStart = upper - offset
        var appendRows = rows - appendStart
        var limited = false
        if height + appendRows > maxHeight {
            appendRows = max(0, maxHeight - height)
            limited = true
        }
        output.append(contentsOf: frame.pixels[(appendStart * rowBytes)..<((appendStart + appendRows) * rowBytes)])
        height += appendRows
        self.reference = signature
        if limited {
            isFull = true
            return .limitReached
        }
        return .appended(rows: offset)
    }

    public func makeImage(colorSpace: CGColorSpace, bitmapInfo: CGBitmapInfo) -> CGImage? {
        Self.image(bytes: output, width: width, height: height, colorSpace: colorSpace, bitmapInfo: bitmapInfo)
    }

    /// Nearest-neighbor downscaled copy for live previews.
    public func previewImage(maxWidth: Int, colorSpace: CGColorSpace, bitmapInfo: CGBitmapInfo) -> CGImage? {
        guard height > 0, width > 0, maxWidth > 0 else { return nil }
        let step = max(1, Int((Double(width) / Double(maxWidth)).rounded(.up)))
        let previewWidth = (width + step - 1) / step
        let previewHeight = (height + step - 1) / step
        var data = [UInt8](repeating: 0, count: previewWidth * previewHeight * 4)
        output.withUnsafeBufferPointer { source in
            data.withUnsafeMutableBufferPointer { target in
                for py in 0..<previewHeight {
                    let sourceRow = py * step * width * 4
                    let targetRow = py * previewWidth * 4
                    for px in 0..<previewWidth {
                        let s = sourceRow + px * step * 4
                        let t = targetRow + px * 4
                        target[t] = source[s]
                        target[t + 1] = source[s + 1]
                        target[t + 2] = source[s + 2]
                        target[t + 3] = source[s + 3]
                    }
                }
            }
        }
        return Self.image(bytes: data, width: previewWidth, height: previewHeight, colorSpace: colorSpace, bitmapInfo: bitmapInfo)
    }

    static func image(bytes: [UInt8], width: Int, height: Int, colorSpace: CGColorSpace, bitmapInfo: CGBitmapInfo) -> CGImage? {
        guard width > 0, height > 0, let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// Most voted vertical offset `d` such that current row `i` shows reference row `i + d`.
    static func bestOffset(reference: Signature, current: Signature, lower: Int, upper: Int) -> Int? {
        let segments = reference.segments
        var index: [UInt64: [Int32]] = [:]
        index.reserveCapacity((upper - lower) * segments)
        for row in lower..<upper {
            for segment in 0..<segments where !reference.uniform[row * segments + segment] {
                let key = Signature.key(reference.hashes[row * segments + segment], segment: segment)
                index[key, default: []].append(Int32(row))
            }
        }
        let span = upper - lower
        var votes = [Int](repeating: 0, count: 2 * span + 1)
        for row in lower..<upper {
            for segment in 0..<segments where !current.uniform[row * segments + segment] {
                let key = Signature.key(current.hashes[row * segments + segment], segment: segment)
                // Rows that repeat many times (stripes, separators) carry no position information.
                guard let candidates = index[key], candidates.count <= 12 else { continue }
                for candidate in candidates {
                    votes[Int(candidate) - row + span] += 1
                }
            }
        }
        var best = -1
        var bestVotes = 0
        for (slot, count) in votes.enumerated() where count > bestVotes {
            best = slot
            bestVotes = count
        }
        return best >= 0 ? best - span : nil
    }
}

/// Per-row, per-segment fingerprints of a frame.
struct Signature {
    let rows: Int
    let segments: Int
    let hashes: [UInt64]
    let uniform: [Bool]
    let informativeRows: [Bool]

    init(frame: StitchFrame, segments: Int) {
        let rows = frame.height
        let width = frame.width
        let bounds = (0...segments).map { $0 * width / segments }
        var hashes = [UInt64](repeating: 0, count: rows * segments)
        var uniform = [Bool](repeating: true, count: rows * segments)
        var informativeRows = [Bool](repeating: false, count: rows)
        frame.pixels.withUnsafeBytes { raw in
            for row in 0..<rows {
                let rowOffset = row * width * 4
                var rowInformative = false
                for segment in 0..<segments {
                    let x0 = bounds[segment]
                    let x1 = bounds[segment + 1]
                    guard x1 > x0 else { continue }
                    // Alpha is the most significant byte for both BGRA and RGBA on little-endian.
                    let first = raw.loadUnaligned(fromByteOffset: rowOffset + x0 * 4, as: UInt32.self) & 0x00FF_FFFF
                    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
                    var isUniform = true
                    for x in x0..<x1 {
                        let value = raw.loadUnaligned(fromByteOffset: rowOffset + x * 4, as: UInt32.self) & 0x00FF_FFFF
                        if value != first { isUniform = false }
                        hash = (hash ^ UInt64(value)) &* 0x0000_0100_0000_01B3
                    }
                    hashes[row * segments + segment] = hash
                    uniform[row * segments + segment] = isUniform
                    if !isUniform { rowInformative = true }
                }
                informativeRows[row] = rowInformative
            }
        }
        self.rows = rows
        self.segments = segments
        self.hashes = hashes
        self.uniform = uniform
        self.informativeRows = informativeRows
    }

    /// Rows match when at least 75% of their segments are identical.
    static func similar(_ a: Signature, _ rowA: Int, _ b: Signature, _ rowB: Int) -> Bool {
        var equal = 0
        let baseA = rowA * a.segments
        let baseB = rowB * b.segments
        for segment in 0..<a.segments where a.hashes[baseA + segment] == b.hashes[baseB + segment] {
            equal += 1
        }
        return equal * 4 >= a.segments * 3
    }

    static func key(_ hash: UInt64, segment: Int) -> UInt64 {
        hash ^ (UInt64(segment + 1) &* 0x9E37_79B9_7F4A_7C15)
    }
}
