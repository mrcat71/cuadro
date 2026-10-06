import Foundation

public extension PixelBuffer {
    /// Bounding rectangle of pixels with alpha above `threshold`, or nil when all are transparent.
    /// Used to trim the empty margin around window captures with shadows.
    func visibleBounds(alphaAbove threshold: UInt8 = 0) -> PixelRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        bytes.withUnsafeBufferPointer { pixels in
            for y in 0..<height {
                let row = y * width * 4
                for x in 0..<width where pixels[row + x * 4 + 3] > threshold {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Average color of the pixels inside `rect`.
    func averageColor(in rect: PixelRect) -> RGBAColor? {
        let area = rect.clamped(width: width, height: height)
        guard !area.isEmpty else { return nil }
        var sum = (0.0, 0.0, 0.0, 0.0)
        for y in area.y..<area.maxY {
            for x in area.x..<area.maxX {
                let color = color(x: x, y: y)
                sum.0 += color.red * color.alpha
                sum.1 += color.green * color.alpha
                sum.2 += color.blue * color.alpha
                sum.3 += color.alpha
            }
        }
        let count = Double(area.width * area.height)
        guard sum.3 > 0 else { return .clear }
        return RGBAColor(red: sum.0 / sum.3, green: sum.1 / sum.3, blue: sum.2 / sum.3, alpha: sum.3 / count)
    }

    /// Most common color in the one-pixel ring just outside `rect`; sides that fall outside
    /// the image are sampled from just inside instead. Used by the smart eraser.
    func dominantSurroundingColor(of rect: PixelRect) -> RGBAColor? {
        guard width > 0, height > 0 else { return nil }
        var samples: [(Int, Int)] = []
        let left = rect.x - 1 >= 0 ? rect.x - 1 : rect.x
        let right = rect.maxX < width ? rect.maxX : rect.maxX - 1
        let top = rect.y - 1 >= 0 ? rect.y - 1 : rect.y
        let bottom = rect.maxY < height ? rect.maxY : rect.maxY - 1
        for x in left...max(left, right) {
            samples.append((x, top))
            samples.append((x, bottom))
        }
        if bottom > top + 1 {
            for y in (top + 1)..<bottom {
                samples.append((left, y))
                samples.append((right, y))
            }
        }

        var buckets: [Int: (count: Int, sum: (Int, Int, Int, Int))] = [:]
        for (x, y) in samples where contains(x: x, y: y) {
            let (r, g, b, a) = rgba(x: x, y: y)
            let key = (Int(r) >> 3) << 15 | (Int(g) >> 3) << 10 | (Int(b) >> 3) << 5 | (Int(a) >> 3)
            var entry = buckets[key] ?? (0, (0, 0, 0, 0))
            entry.count += 1
            entry.sum = (entry.sum.0 + Int(r), entry.sum.1 + Int(g), entry.sum.2 + Int(b), entry.sum.3 + Int(a))
            buckets[key] = entry
        }
        guard let best = buckets.values.max(by: { $0.count < $1.count }) else { return nil }
        let n = best.count
        let alpha = Double(best.sum.3) / Double(n) / 255
        guard alpha > 0 else { return .clear }
        return RGBAColor(
            red: min(1, Double(best.sum.0) / Double(n) / 255 / alpha),
            green: min(1, Double(best.sum.1) / Double(n) / 255 / alpha),
            blue: min(1, Double(best.sum.2) / Double(n) / 255 / alpha),
            alpha: alpha
        )
    }

    /// Shrinks `rect` while its outermost rows and columns match the border color (pixel at the
    /// rect's top-left corner) within `tolerance`. Returns `rect` when everything is uniform.
    func trimmedContentRect(_ rect: PixelRect, tolerance: Int = 4) -> PixelRect {
        var area = rect.clamped(width: width, height: height)
        guard !area.isEmpty else { return rect }
        let border = rgba(x: area.x, y: area.y)
        func rowUniform(_ y: Int) -> Bool {
            for x in area.x..<area.maxX where EdgeFinder.differs(rgba(x: x, y: y), border, tolerance: tolerance) {
                return false
            }
            return true
        }
        func columnUniform(_ x: Int) -> Bool {
            for y in area.y..<area.maxY where EdgeFinder.differs(rgba(x: x, y: y), border, tolerance: tolerance) {
                return false
            }
            return true
        }
        while area.height > 0, rowUniform(area.y) {
            area.y += 1
            area.height -= 1
        }
        guard area.height > 0 else { return rect }
        while area.height > 1, rowUniform(area.maxY - 1) { area.height -= 1 }
        while area.width > 1, columnUniform(area.x) {
            area.x += 1
            area.width -= 1
        }
        while area.width > 1, columnUniform(area.maxX - 1) { area.width -= 1 }
        return area
    }
}
