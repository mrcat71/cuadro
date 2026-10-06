import AppKit
import CuadroKit

/// A frozen image of one display, taken before the selection overlay appears.
struct DisplaySnapshot {
    let displayID: CGDirectDisplayID
    /// Display frame in Cocoa global coordinates.
    let frame: CGRect
    /// Pixels per point.
    let scale: CGFloat
    let image: CGImage

    /// Crops a rect given in display-local y-down points.
    func crop(_ localRect: CGRect) -> CGImage? {
        let pixels = localRect.scaled(by: scale).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { return nil }
        return image.cropping(to: pixels)
    }

    /// Cocoa global rect for a display-local y-down rect.
    func globalRect(fromLocal rect: CGRect) -> CGRect {
        ScreenCoordinates.cocoaRect(fromLocalTopLeft: rect, screenFrame: frame)
    }
}

/// An on-screen window from the window server list.
struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let title: String
    /// Cocoa global coordinates.
    let frame: CGRect
    let layer: Int
}

/// A finished capture on its way to the clipboard, disk, editor or thumbnail.
struct CaptureResult {
    enum Kind {
        case area, window, fullscreen, scrolling, file, clipboard
    }

    var image: CGImage
    var scale: CGFloat
    var kind: Kind
    /// Where the content was on screen (Cocoa global), if known.
    var screenRect: CGRect?
    /// Frontmost app at capture time, for the `{app}` file name token.
    var appName: String?
    var title: String?
}

enum CaptureError: LocalizedError {
    case noDisplays
    case windowNotFound
    case permissionDenied
    case emptySelection

    var errorDescription: String? {
        switch self {
        case .noDisplays: "No display is available for capture."
        case .windowNotFound: "That window is no longer on screen."
        case .permissionDenied: "Cuadro is not allowed to record the screen."
        case .emptySelection: "The selection is empty."
        }
    }
}
