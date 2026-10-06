import CoreGraphics
import Foundation

/// Draggable handles of a selected annotation.
public enum AnnotationHandle: Hashable, Sendable {
    case start
    case end
    case bend
    case corner(RectHandle)
}

public extension Annotation {
    static func counterRadius(fontSize: CGFloat) -> CGFloat { max(10, fontSize * 0.8) }

    /// Control point of a curved arrow, if any.
    var curveControl: CGPoint? {
        guard kind == .arrow, let bend else { return nil }
        return Geometry.quadControl(start: start, end: end, through: bend)
    }

    /// Centerline of segment-like annotations (sampled for curved arrows).
    var centerline: [CGPoint] {
        if let control = curveControl {
            return Geometry.quadPolyline(start, control, end)
        }
        return [start, end]
    }

    /// Area covered by the annotation, including strokes, heads and labels.
    var bounds: CGRect {
        switch kind {
        case .arrow, .line, .measure:
            let pad: CGFloat
            switch kind {
            case .arrow: pad = max(style.lineWidth * 2.2, 8)
            case .measure: pad = max(style.fontSize * 1.6, 16)
            default: pad = max(style.lineWidth, 4)
            }
            return Geometry.boundingBox(of: centerline).insetBy(dx: -pad, dy: -pad)
        case .pen:
            return Geometry.boundingBox(of: points).insetBy(dx: -style.lineWidth, dy: -style.lineWidth)
        case .text:
            return CGRect(origin: start, size: TextLayout.size(of: text, style: style))
        case .counter:
            let radius = Self.counterRadius(fontSize: style.fontSize)
            return CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)
        case .rectangle, .ellipse:
            return rect.insetBy(dx: -style.lineWidth / 2, dy: -style.lineWidth / 2)
        case .magnifier:
            return rect.insetBy(dx: -style.lineWidth, dy: -style.lineWidth)
        default:
            return rect
        }
    }

    /// Whether `point` (document points) touches the annotation. `tolerance` widens thin strokes.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .arrow, .line, .measure:
            let reach = max(style.lineWidth, 2) / 2 + tolerance + (kind == .arrow ? style.lineWidth : 0)
            return Geometry.distance(from: point, toPolyline: centerline) <= reach
        case .pen:
            return Geometry.distance(from: point, toPolyline: points) <= style.lineWidth / 2 + tolerance
        case .rectangle:
            let outer = rect.insetBy(dx: -(style.lineWidth / 2 + tolerance), dy: -(style.lineWidth / 2 + tolerance))
            guard outer.contains(point) else { return false }
            if style.fill != .none { return true }
            let inner = rect.insetBy(dx: style.lineWidth / 2 + tolerance, dy: style.lineWidth / 2 + tolerance)
            return inner.isEmpty || !inner.contains(point)
        case .ellipse:
            let r = rect
            guard r.width > 0, r.height > 0 else { return false }
            let nx = (point.x - r.midX) / (r.width / 2)
            let ny = (point.y - r.midY) / (r.height / 2)
            let distance = (nx * nx + ny * ny).squareRoot()
            if style.fill != .none { return distance <= 1 + tolerance / min(r.width, r.height) * 2 }
            let band = (style.lineWidth / 2 + tolerance) / (min(r.width, r.height) / 2)
            return abs(distance - 1) <= band
        case .counter:
            return point.distance(to: start) <= Self.counterRadius(fontSize: style.fontSize) + tolerance
        case .magnifier:
            let r = rect.insetBy(dx: -tolerance, dy: -tolerance)
            guard r.width > 0, r.height > 0 else { return false }
            let nx = (point.x - r.midX) / (r.width / 2)
            let ny = (point.y - r.midY) / (r.height / 2)
            return nx * nx + ny * ny <= 1
        default:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    /// Handles shown while selected, with their positions.
    var handles: [(handle: AnnotationHandle, point: CGPoint)] {
        switch kind {
        case .arrow:
            return [(.start, start), (.end, end), (.bend, bend ?? start.midpoint(end))]
        case .line, .measure:
            return [(.start, start), (.end, end)]
        case .pen, .text, .counter:
            return []
        default:
            return RectHandle.allCases.map { (.corner($0), $0.point(in: rect)) }
        }
    }

    /// Nearest handle within `radius` of `point`.
    func handle(at point: CGPoint, radius: CGFloat) -> AnnotationHandle? {
        handles
            .map { ($0.handle, $0.point.distance(to: point)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?
            .0
    }

    mutating func translate(by delta: CGPoint) {
        start = start + delta
        end = end + delta
        bend = bend.map { $0 + delta }
        points = points.map { $0 + delta }
    }

    /// Drags `handle` to `point`. `constrained` snaps angles or keeps the aspect ratio (Shift).
    mutating func move(_ handle: AnnotationHandle, to point: CGPoint, constrained: Bool) {
        switch handle {
        case .start:
            start = constrained ? Geometry.snapAngle(from: end, to: point) : point
        case .end:
            end = constrained ? Geometry.snapAngle(from: start, to: point) : point
        case .bend:
            bend = point
        case .corner(let corner):
            let current = rect
            let aspect: CGFloat?
            if kind == .magnifier {
                aspect = 1
            } else if kind == .image || constrained, current.height > 0 {
                aspect = current.width / current.height
            } else {
                aspect = nil
            }
            let resized = corner.resize(current, to: point, aspect: aspect)
            start = CGPoint(x: resized.minX, y: resized.minY)
            end = CGPoint(x: resized.maxX, y: resized.maxY)
        }
    }

    /// Too small to keep after creation.
    var isDegenerate: Bool {
        switch kind {
        case .arrow, .line, .measure:
            return start.distance(to: end) < 4
        case .pen:
            return points.count < 2
        case .text:
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .counter:
            return false
        default:
            return rect.width < 3 || rect.height < 3
        }
    }
}
