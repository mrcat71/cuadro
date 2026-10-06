import CoreGraphics
import Foundation

/// Outlines for arrow annotations.
public enum ArrowGeometry {
    public struct Metrics: Equatable, Sendable {
        public var headLength: CGFloat
        public var headWidth: CGFloat
        public var shaftWidth: CGFloat
    }

    /// Head and shaft proportions for a stroke width; heads shrink on very short arrows.
    public static func metrics(lineWidth: CGFloat, length: CGFloat) -> Metrics {
        var headLength = max(lineWidth * 3.6, 12)
        var headWidth = max(lineWidth * 3.0, 11)
        let limit = length * 0.45
        if headLength > limit, headLength > 0 {
            let factor = max(limit, 1) / headLength
            headLength *= factor
            headWidth *= factor
        }
        return Metrics(headLength: headLength, headWidth: headWidth, shaftWidth: max(lineWidth, 1))
    }

    /// Filled outline of a straight arrow with a tapered tail (or a second head).
    public static func straightArrowPath(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat, doubleHeaded: Bool) -> CGPath {
        let path = CGMutablePath()
        let delta = end - start
        let length = delta.length
        guard length > 0 else { return path }
        let m = metrics(lineWidth: lineWidth, length: length)
        let u = delta.normalized
        let n = CGPoint(x: -u.y, y: u.x)
        let shaftHalf = m.shaftWidth / 2
        let headHalf = m.headWidth / 2
        let endBase = end - u * m.headLength

        if doubleHeaded {
            let startBase = start + u * m.headLength
            path.addLines(between: [
                startBase + n * shaftHalf,
                endBase + n * shaftHalf,
                endBase + n * headHalf,
                end,
                endBase - n * headHalf,
                endBase - n * shaftHalf,
                startBase - n * shaftHalf,
                startBase - n * headHalf,
                start,
                startBase + n * headHalf,
            ])
        } else {
            let tailHalf = shaftHalf * 0.35
            path.addLines(between: [
                start + n * tailHalf,
                endBase + n * shaftHalf,
                endBase + n * headHalf,
                end,
                endBase - n * headHalf,
                endBase - n * shaftHalf,
                start - n * tailHalf,
            ])
        }
        path.closeSubpath()
        return path
    }

    /// Triangle head with its tip at `tip`, pointing along `direction`.
    public static func headPath(tip: CGPoint, direction: CGPoint, metrics m: Metrics) -> CGPath {
        let u = direction.normalized
        let n = CGPoint(x: -u.y, y: u.x)
        let base = tip - u * m.headLength
        let path = CGMutablePath()
        path.addLines(between: [base + n * (m.headWidth / 2), tip, base - n * (m.headWidth / 2)])
        path.closeSubpath()
        return path
    }

    /// Curved arrow through `through`: a shaft to stroke (round caps) and heads to fill.
    public static func curvedArrow(
        from start: CGPoint, to end: CGPoint, through: CGPoint, lineWidth: CGFloat, doubleHeaded: Bool
    ) -> (shaft: CGPath, heads: CGPath) {
        let control = Geometry.quadControl(start: start, end: end, through: through)
        let approximateLength = Geometry.distance(from: through, toSegment: start, end) + start.distance(to: end)
        let m = metrics(lineWidth: lineWidth, length: approximateLength)

        // Stop the shaft before the head so its round cap does not poke through the tip.
        func trimParameter(from tip: CGPoint, towardsStart: Bool) -> CGFloat {
            let target = m.headLength * 0.6
            var t: CGFloat = towardsStart ? 1 : 0
            for step in 0...200 {
                let candidate = towardsStart ? 1 - CGFloat(step) / 200 : CGFloat(step) / 200
                if Geometry.quadPoint(start, control, end, t: candidate).distance(to: tip) >= target {
                    t = candidate
                    break
                }
            }
            return t
        }
        let t1 = trimParameter(from: end, towardsStart: true)
        let t0 = doubleHeaded ? trimParameter(from: start, towardsStart: false) : 0

        let shaft = CGMutablePath()
        let samples = Geometry.quadPolyline(start, control, end, from: t0, to: t1, segments: 40)
        if let first = samples.first {
            shaft.move(to: first)
            for point in samples.dropFirst() { shaft.addLine(to: point) }
        }

        let heads = CGMutablePath()
        heads.addPath(headPath(tip: end, direction: end - control, metrics: m))
        if doubleHeaded {
            heads.addPath(headPath(tip: start, direction: start - control, metrics: m))
        }
        return (shaft, heads)
    }
}
