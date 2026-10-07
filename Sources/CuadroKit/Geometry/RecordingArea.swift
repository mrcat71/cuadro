import CoreGraphics
import Foundation

/// Geometry of the screen recording frame: adjusting it before the recording starts, moving it
/// while recording, and the pixel crop the recorder takes from each display frame. Areas are in
/// display-local y-down points unless a function says otherwise.
public enum RecordingArea {
    /// Smallest area the adjust stage allows, in points.
    public static let minimumSize = CGSize(width: 40, height: 40)

    /// What a pointer press on the adjust stage grabs.
    public enum Hit: Equatable, Sendable {
        case handle(RectHandle)
        case inside
        case outside
    }

    /// Handles win over the inside, so small areas stay resizable.
    public static func hit(_ point: CGPoint, area: CGRect, handleRadius: CGFloat) -> Hit {
        let nearest = RectHandle.allCases
            .map { ($0, $0.point(in: area).distance(to: point)) }
            .min { $0.1 < $1.1 }
        if let nearest, nearest.1 <= handleRadius {
            return .handle(nearest.0)
        }
        return area.contains(point) ? .inside : .outside
    }

    /// `area` offset by `delta`, kept inside `bounds` and on the pixel grid of `scale`.
    public static func moved(_ area: CGRect, by delta: CGPoint, within bounds: CGRect, scale: CGFloat) -> CGRect {
        var result = area.offsetBy(dx: delta.x, dy: delta.y).constrained(to: bounds)
        result.origin = snapped(result.origin, scale: scale)
        return result.constrained(to: bounds)
    }

    /// Drags `handle` of `area` to `point`. The opposite edges stay put, the dragged edges stop at
    /// `bounds` and never come closer than `minimumSize` to the opposite ones.
    public static func resized(_ area: CGRect, handle: RectHandle, to point: CGPoint, within bounds: CGRect, scale: CGFloat) -> CGRect {
        let x = min(max(point.x, bounds.minX), bounds.maxX)
        let y = min(max(point.y, bounds.minY), bounds.maxY)
        var minX = area.minX, minY = area.minY, maxX = area.maxX, maxY = area.maxY
        switch handle {
        case .topLeft, .left, .bottomLeft: minX = min(x, maxX - minimumSize.width)
        case .topRight, .right, .bottomRight: maxX = max(x, minX + minimumSize.width)
        case .top, .bottom: break
        }
        switch handle {
        case .topLeft, .top, .topRight: minY = min(y, maxY - minimumSize.height)
        case .bottomLeft, .bottom, .bottomRight: maxY = max(y, minY + minimumSize.height)
        case .left, .right: break
        }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return rect.snapped(toScale: scale).constrained(to: bounds)
    }

    /// The area a fresh drag from `start` to `current` selects, or nil while it is too small.
    public static func drawn(from start: CGPoint, to current: CGPoint, within bounds: CGRect, scale: CGFloat) -> CGRect? {
        let rect = Geometry.dragRect(from: start, to: current).intersection(bounds).snapped(toScale: scale)
        guard !rect.isNull, rect.width >= minimumSize.width, rect.height >= minimumSize.height else { return nil }
        return rect
    }

    /// Bottom-left corner of the recording controls (Cocoa y-up points): centered below the area
    /// if there is room, else above it, else inside its bottom edge, always on the screen.
    public static func controlsOrigin(for area: CGRect, controlsSize size: CGSize, screen: CGRect) -> CGPoint {
        var origin = CGPoint(x: area.midX - size.width / 2, y: area.minY - size.height - 10)
        if origin.y < screen.minY + 8 { origin.y = area.maxY + 10 }
        if origin.y + size.height > screen.maxY - 8 { origin.y = area.minY + 12 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        return origin
    }

    /// Movie dimensions for `area`: whole pixels, even (video encoders want that), at least 2.
    public static func pixelSize(of area: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        (max(2, Int((area.width * scale).rounded()) & ~1), max(2, Int((area.height * scale).rounded()) & ~1))
    }

    /// Top-left pixel of the crop for `area`, kept inside a frame of `frameSize` pixels for a crop
    /// of `cropSize` pixels.
    public static func cropOrigin(of area: CGRect, scale: CGFloat, cropSize: CGSize, frameSize: CGSize) -> CGPoint {
        CGPoint(
            x: min(max((area.minX * scale).rounded(), 0), max(0, frameSize.width - cropSize.width)),
            y: min(max((area.minY * scale).rounded(), 0), max(0, frameSize.height - cropSize.height))
        )
    }

    private static func snapped(_ point: CGPoint, scale: CGFloat) -> CGPoint {
        guard scale > 0 else { return point }
        return CGPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }
}

/// Eases a moving position towards its target, so a dragged recording frame pans the movie
/// smoothly instead of jumping with every pointer event.
public enum Smoothing {
    /// Exponential approach: after `elapsed` seconds the remaining distance shrinks by
    /// e^(-elapsed / timeConstant). Lands exactly on `target` once within `snapDistance`.
    public static func approach(_ current: CGPoint, to target: CGPoint, elapsed: TimeInterval, timeConstant: TimeInterval, snapDistance: CGFloat) -> CGPoint {
        guard timeConstant > 0, elapsed > 0 else { return current.distance(to: target) <= snapDistance ? target : current }
        let factor = CGFloat(1 - exp(-elapsed / timeConstant))
        let next = current + (target - current) * factor
        return next.distance(to: target) <= snapDistance ? target : next
    }
}
