import AppKit

/// Dims every display the moment a selection starts, while ScreenCaptureKit still takes the
/// frozen screenshots the overlay shows, so the shortcut answers at once instead of after them.
/// The screenshots leave it out, and the overlay, which looks the same until something is
/// selected, takes its place.
final class CaptureCurtain {
    /// The overlay's dimming before anything is selected or highlighted.
    static let dimming = NSColor.black.withAlphaComponent(0.2)
    /// Screenshots take well under half a second, but ScreenCaptureKit can stall for seconds or
    /// wait on its monthly permission alert, which the curtain would cover and keep from being
    /// clicked. After this long it lifts, and the overlay shows whenever the screenshots are in.
    private static let timeout: Duration = .seconds(2)

    private var panels: [FloatingPanel] = []

    /// For the screenshots to wait for: they can leave the curtain out only once the window
    /// server lists it.
    var windows: [NSWindow] { panels }

    init() {
        for screen in NSScreen.screens {
            // Not click-through: a click while it waits must not reach the app underneath.
            let panel = FloatingPanel(level: .screenSaver)
            panel.backgroundColor = Self.dimming
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            ScreenCaptureService.shared.exclude(panel)
            panels.append(panel)
        }
        Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            guard let self, !panels.isEmpty else { return }
            Log.capture.notice("No screenshots after \(Self.timeout.milliseconds, format: .fixed(precision: 0)) ms, lifting the curtain")
            remove()
        }
    }

    func remove() {
        for panel in panels {
            panel.orderOut(nil)
            ScreenCaptureService.shared.include(panel)
        }
        panels.removeAll()
    }
}
