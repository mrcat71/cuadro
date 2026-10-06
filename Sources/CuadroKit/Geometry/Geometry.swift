import CoreGraphics
import Foundation

public extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint { CGPoint(x: lhs.x * rhs, y: lhs.y * rhs) }

    var length: CGFloat { hypot(x, y) }

    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }

    func midpoint(_ other: CGPoint) -> CGPoint { CGPoint(x: (x + other.x) / 2, y: (y + other.y) / 2) }

    /// Unit vector in the same direction, or zero for a zero vector.
    var normalized: CGPoint {
        let len = length
        return len > 0 ? CGPoint(x: x / len, y: y / len) : .zero
    }
}

public extension CGRect {
    /// Normalized rectangle spanning two corner points given in any order.
    init(corners a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Rounds the edges to the nearest pixel boundary for the given points-to-pixels scale.
    func snapped(toScale scale: CGFloat) -> CGRect {
        guard scale > 0 else { return self }
        let minX = (self.minX * scale).rounded() / scale
        let minY = (self.minY * scale).rounded() / scale
        let maxX = (self.maxX * scale).rounded() / scale
        let maxY = (self.maxY * scale).rounded() / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Moves the rectangle inside `bounds` without resizing, shrinking only when it does not fit.
    func constrained(to bounds: CGRect) -> CGRect {
        var result = self
        result.size.width = min(result.width, bounds.width)
        result.size.height = min(result.height, bounds.height)
        result.origin.x = min(max(result.minX, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.minY, bounds.minY), bounds.maxY - result.height)
        return result
    }

    func scaled(by factor: CGFloat) -> CGRect {
        CGRect(x: minX * factor, y: minY * factor, width: width * factor, height: height * factor)
    }
}

public enum Geometry {
    /// Rectangle produced by dragging from `start` to `current`.
    /// - Parameters:
    ///   - square: force equal width and height (Shift).
    ///   - fromCenter: treat `start` as the center (Option).
    public static func dragRect(from start: CGPoint, to current: CGPoint, square: Bool = false, fromCenter: Bool = false) -> CGRect {
        var dx = current.x - start.x
        var dy = current.y - start.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        if fromCenter {
            return CGRect(x: start.x - abs(dx), y: start.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
        }
        return CGRect(corners: start, CGPoint(x: start.x + dx, y: start.y + dy))
    }

    /// Snaps the direction from `origin` to `point` to a multiple of `step` radians, keeping the distance.
    public static func snapAngle(from origin: CGPoint, to point: CGPoint, step: CGFloat = .pi / 4) -> CGPoint {
        let delta = point - origin
        let length = delta.length
        guard length > 0, step > 0 else { return point }
        let angle = (atan2(delta.y, delta.x) / step).rounded() * step
        return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    public static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = b - a
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        guard lengthSquared > 0 else { return point.distance(to: a) }
        let t = max(0, min(1, ((point.x - a.x) * ab.x + (point.y - a.y) * ab.y) / lengthSquared))
        return point.distance(to: CGPoint(x: a.x + ab.x * t, y: a.y + ab.y * t))
    }

    public static func distance(from point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return point.distance(to: first) }
        var best = CGFloat.infinity
        for index in 1..<points.count {
            best = min(best, distance(from: point, toSegment: points[index - 1], points[index]))
        }
        return best
    }

    /// Point on a quadratic Bezier curve at parameter `t`.
    public static func quadPoint(_ p0: CGPoint, _ control: CGPoint, _ p1: CGPoint, t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return CGPoint(
            x: mt * mt * p0.x + 2 * mt * t * control.x + t * t * p1.x,
            y: mt * mt * p0.y + 2 * mt * t * control.y + t * t * p1.y
        )
    }

    /// Control point of the quadratic curve from `start` to `end` that passes through `through` at t = 0.5.
    public static func quadControl(start: CGPoint, end: CGPoint, through: CGPoint) -> CGPoint {
        CGPoint(x: 2 * through.x - 0.5 * (start.x + end.x), y: 2 * through.y - 0.5 * (start.y + end.y))
    }

    /// Samples a quadratic curve between parameters `from` and `to`.
    public static func quadPolyline(
        _ p0: CGPoint, _ control: CGPoint, _ p1: CGPoint,
        from t0: CGFloat = 0, to t1: CGFloat = 1, segments: Int = 32
    ) -> [CGPoint] {
        let count = max(1, segments)
        return (0...count).map { step in
            let t = t0 + (t1 - t0) * CGFloat(step) / CGFloat(count)
            return quadPoint(p0, control, p1, t: t)
        }
    }

    /// Smallest rectangle containing all points.
    public static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// The eight resize handles of a rectangle in y-down coordinates.
public enum RectHandle: Int, CaseIterable, Codable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    public func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    public var opposite: RectHandle {
        switch self {
        case .topLeft: .bottomRight
        case .top: .bottom
        case .topRight: .bottomLeft
        case .right: .left
        case .bottomRight: .topLeft
        case .bottom: .top
        case .bottomLeft: .topRight
        case .left: .right
        }
    }

    public var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: true
        default: false
        }
    }

    /// Resizes `rect` by dragging this handle to `point` while the opposite side stays fixed.
    /// - Parameter aspect: optional width / height ratio to preserve.
    public func resize(_ rect: CGRect, to point: CGPoint, aspect: CGFloat? = nil) -> CGRect {
        if let aspect, aspect > 0 {
            return resizeKeepingAspect(rect, to: point, aspect: aspect)
        }
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch self {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        }
        return CGRect(corners: CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY))
    }

    private func resizeKeepingAspect(_ rect: CGRect, to point: CGPoint, aspect: CGFloat) -> CGRect {
        let anchor = opposite.point(in: rect)
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            let dx = point.x - anchor.x
            let dy = point.y - anchor.y
            var width = abs(dx)
            var height = abs(dy)
            if width / max(height, .ulpOfOne) > aspect { height = width / aspect } else { width = height * aspect }
            let corner = CGPoint(x: anchor.x + (dx < 0 ? -width : width), y: anchor.y + (dy < 0 ? -height : height))
            return CGRect(corners: anchor, corner)
        case .top, .bottom:
            let height = abs(point.y - anchor.y)
            let width = height * aspect
            let y = point.y < anchor.y ? anchor.y - height : anchor.y
            return CGRect(x: rect.midX - width / 2, y: y, width: width, height: height)
        case .left, .right:
            let width = abs(point.x - anchor.x)
            let height = width / aspect
            let x = point.x < anchor.x ? anchor.x - width : anchor.x
            return CGRect(x: x, y: rect.midY - height / 2, width: width, height: height)
        }
    }
}

/// Conversions between Cocoa global coordinates (origin at the bottom-left of the primary
/// screen, y up) and Quartz global coordinates (origin at its top-left, y down).
public struct ScreenCoordinates: Equatable, Sendable {
    public let primaryScreenHeight: CGFloat

    public init(primaryScreenHeight: CGFloat) {
        self.primaryScreenHeight = primaryScreenHeight
    }

    /// The mapping is its own inverse, so this converts in both directions.
    public func flip(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public func flip(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// Converts a rect in a screen's local y-down space (origin at its top-left) to global Cocoa space.
    public static func cocoaRect(fromLocalTopLeft local: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + local.minX, y: screenFrame.maxY - local.maxY, width: local.width, height: local.height)
    }

    /// Converts a global Cocoa rect into a screen's local y-down space.
    public static func localTopLeft(fromCocoa rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: rect.minX - screenFrame.minX, y: screenFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func localTopLeft(fromCocoa point: CGPoint, screenFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x - screenFrame.minX, y: screenFrame.maxY - point.y)
    }
}
