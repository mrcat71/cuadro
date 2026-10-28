import CoreGraphics
import Foundation

/// Where the camera bubble of a screen recording sits in the recording area, in the area's
/// coordinate space (display-local y-down points). Its place is an anchor: 0 to 1 across the room
/// the area leaves the bubble inside its margins, so (0, 1) is the bottom-left corner, and the
/// bubble keeps its corner when the area is resized or moved.
public enum CameraBubbleLayout {
    /// The bubble's diameter where the area has room for it, in points.
    public static let preferredDiameter: CGFloat = 180
    /// Distance from the area's edges.
    public static let margin: CGFloat = 16
    /// A bubble that would come out smaller than this is left out.
    public static let minimumDiameter: CGFloat = 40
    /// Where a bubble goes the first time: the bottom-left corner.
    public static let defaultAnchor = CGPoint(x: 0, y: 1)

    /// The bubble's diameter in an area of `size`: `preferredDiameter`, at most half the area's
    /// shorter side, or nil when that is below `minimumDiameter`.
    public static func diameter(in size: CGSize) -> CGFloat? {
        let diameter = min(preferredDiameter, (min(size.width, size.height) / 2).rounded(.down))
        return diameter >= minimumDiameter ? diameter : nil
    }

    /// The bubble's frame for `anchor` in `area`.
    public static func frame(anchor: CGPoint, diameter: CGFloat, in area: CGRect) -> CGRect {
        let room = room(for: diameter, in: area)
        let x = room.minX + clamp(anchor.x) * room.width
        let y = room.minY + clamp(anchor.y) * room.height
        return CGRect(x: x, y: y, width: diameter, height: diameter)
    }

    /// The anchor of a bubble with its top-left corner at `origin` in `area`, the bubble kept
    /// inside the area's margins: what a drag of the bubble to `origin` sets.
    public static func anchor(origin: CGPoint, diameter: CGFloat, in area: CGRect) -> CGPoint {
        let room = room(for: diameter, in: area)
        return CGPoint(
            x: room.width > 0 ? clamp((origin.x - room.minX) / room.width) : 0.5,
            y: room.height > 0 ? clamp((origin.y - room.minY) / room.height) : 0.5
        )
    }

    /// The top-left corners a bubble of `diameter` can have in `area`: inside the margins, or
    /// centered on an axis without room for them.
    private static func room(for diameter: CGFloat, in area: CGRect) -> CGRect {
        func span(_ minimum: CGFloat, _ length: CGFloat) -> (CGFloat, CGFloat) {
            let free = length - 2 * margin - diameter
            return free > 0 ? (minimum + margin, free) : (minimum + (length - diameter) / 2, 0)
        }
        let (x, width) = span(area.minX, area.width)
        let (y, height) = span(area.minY, area.height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}
