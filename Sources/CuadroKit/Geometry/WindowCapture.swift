import CoreGraphics

/// Geometry for capturing a picked window on its own. Frames are Quartz global points (origin
/// at the top-left of the primary display, y down), as ScreenCaptureKit reports them.
public enum WindowCapture {
    /// Whether ScreenCaptureKit's single-window filter would bring in more than the window itself.
    /// It captures a sheet or another window attached to a parent together with that parent, so
    /// picking a dialog in front of an app's window gave the whole window.
    /// - Parameters:
    ///   - frame: the picked window's frame.
    ///   - filterSize: the size of the single-window filter's `contentRect`.
    ///   - sameAppFrames: frames of the app's other on-screen windows on the same layer.
    public static func needsIsolation(frame: CGRect, filterSize: CGSize, sameAppFrames: [CGRect]) -> Bool {
        let tolerance: CGFloat = 1
        if abs(filterSize.width - frame.width) > tolerance || abs(filterSize.height - frame.height) > tolerance {
            return true
        }
        return sameAppFrames.contains { other in
            other.contains(frame) && (other.width > frame.width || other.height > frame.height)
        }
    }

    /// Index of the display that shows most of `frame`, or nil when it is on none of them.
    public static func display(for frame: CGRect, among displays: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, display) in displays.enumerated() {
            let overlap = display.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > 0, area > (best?.area ?? 0) { best = (index, area) }
        }
        return best?.index
    }

    /// The display-local rect to capture for `frame` with `margin` around it (room for the
    /// shadow), kept on the display; nil when nothing of it is on the display.
    public static func sourceRect(frame: CGRect, margin: CGFloat, displayBounds: CGRect) -> CGRect? {
        let rect = frame.insetBy(dx: -margin, dy: -margin).intersection(displayBounds)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        return rect.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
    }
}
