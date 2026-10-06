import AppKit
import CuadroKit
@preconcurrency import ScreenCaptureKit

/// ScreenCaptureKit wrappers for display and window screenshots.
final class ScreenCaptureService {
    static let shared = ScreenCaptureService()

    /// Cuadro's own transient windows (HUDs, toasts, thumbnails) that must never be captured.
    private var excludedWindowIDs = Set<CGWindowID>()

    func exclude(_ window: NSWindow) {
        guard window.windowNumber > 0 else { return }
        excludedWindowIDs.insert(CGWindowID(window.windowNumber))
    }

    func include(_ window: NSWindow) {
        excludedWindowIDs.remove(CGWindowID(window.windowNumber))
    }

    func isExcluded(_ windowID: CGWindowID) -> Bool { excludedWindowIDs.contains(windowID) }

    /// Captures every display at native resolution.
    func snapshotAllDisplays(showCursor: Bool) async throws -> [DisplaySnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var snapshots: [DisplaySnapshot] = []
        for display in content.displays {
            if let snapshot = try await snapshot(display: display, content: content, showCursor: showCursor) {
                snapshots.append(snapshot)
            }
        }
        guard !snapshots.isEmpty else { throw CaptureError.noDisplays }
        return snapshots
    }

    /// Captures one display.
    func snapshotDisplay(_ displayID: CGDirectDisplayID, showCursor: Bool) async throws -> DisplaySnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }),
              let snapshot = try await snapshot(display: display, content: content, showCursor: showCursor)
        else { throw CaptureError.noDisplays }
        return snapshot
    }

    private func snapshot(display: SCDisplay, content: SCShareableContent, showCursor: Bool) async throws -> DisplaySnapshot? {
        guard let screen = NSScreen.screen(for: display.displayID) else { return nil }
        let excluded = content.windows.filter { excludedWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((filter.contentRect.width * scale).rounded())
        configuration.height = Int((filter.contentRect.height * scale).rounded())
        configuration.showsCursor = showCursor
        configuration.captureResolution = .best
        if AppSettings.shared.convertToSRGB {
            configuration.colorSpaceName = CGColorSpace.sRGB
        }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return DisplaySnapshot(displayID: display.displayID, frame: screen.frame, scale: scale, image: image)
    }

    /// Captures a single window on its own: no overlapping windows, transparent corners,
    /// optional system shadow.
    func captureWindow(_ windowID: CGWindowID, includeShadow: Bool) async throws -> (image: CGImage, scale: CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        // contentRect excludes the shadow and there is no API for the shadow's frame (Apple
        // forums thread 765360). Capture into an oversized surface without upscaling, then trim
        // the transparent margin.
        let margin: CGFloat = includeShadow ? 120 : 0
        let configuration = SCStreamConfiguration()
        configuration.width = Int(((filter.contentRect.width + margin * 2) * scale).rounded())
        configuration.height = Int(((filter.contentRect.height + margin * 2) * scale).rounded())
        configuration.scalesToFit = false
        configuration.ignoreShadowsSingleWindow = !includeShadow
        configuration.shouldBeOpaque = false
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.includeChildWindows = true
        if AppSettings.shared.convertToSRGB {
            configuration.colorSpaceName = CGColorSpace.sRGB
        }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard includeShadow else { return (image, scale) }
        let trimmed = await Task.detached(priority: .userInitiated) { () -> CGImage in
            guard let bounds = PixelBuffer(image: image)?.visibleBounds(),
                  let cropped = image.cropping(to: bounds.cgRect)
            else { return image }
            return cropped
        }.value
        return (trimmed, scale)
    }
}

/// Z-ordered on-screen windows from the window server.
enum WindowList {
    private static let ignoredOwners: Set<String> = [
        "Window Server", "Dock", "Control Center", "Notification Center", "Spotlight", "WindowManager", "Screenshot",
    ]

    static func onScreenWindows() -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let space = ScreenCoordinates(primaryScreenHeight: NSScreen.primaryHeight)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return raw.compactMap { info -> WindowInfo? in
            guard let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.01, bounds.width >= 40, bounds.height >= 24 else { return nil }
            guard (0..<20).contains(layer) || layer == Int(CGWindowLevelForKey(.popUpMenuWindow)) else { return nil }
            guard !ignoredOwners.contains(owner) else { return nil }
            if pid == ownPID, ScreenCaptureService.shared.isExcluded(number) { return nil }
            return WindowInfo(
                id: number, pid: pid, owner: owner,
                title: info[kCGWindowName as String] as? String ?? "",
                frame: space.flip(bounds), layer: layer
            )
        }
    }
}
