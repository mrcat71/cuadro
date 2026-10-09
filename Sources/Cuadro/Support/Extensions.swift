import AppKit
import CuadroKit
import SwiftUI

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }

    /// The screen under the mouse pointer.
    static var withMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) } ?? main
    }

    /// Height of the primary screen, the reference for Quartz/Cocoa conversions.
    static var primaryHeight: CGFloat { screens.first?.frame.height ?? 0 }
}

extension NSImage {
    /// Image whose point size reflects the capture scale.
    convenience init(cgImage: CGImage, scale: CGFloat) {
        self.init(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
    }
}

extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    var pixelSize: CGSize { CGSize(width: width, height: height) }
}

extension Color {
    init(_ color: RGBAColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

extension NSColor {
    convenience init(_ color: RGBAColor) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

extension RGBAColor {
    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent)
    }

    init?(_ color: Color) {
        self.init(NSColor(color))
    }
}

extension Duration {
    /// For timings in the log.
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

extension Notification.Name {
    static let menuBarIconVisibilityChanged = Notification.Name("CuadroMenuBarIconVisibilityChanged")
    static let historyChanged = Notification.Name("CuadroHistoryChanged")
    static let recordingChanged = Notification.Name("CuadroRecordingChanged")
}
