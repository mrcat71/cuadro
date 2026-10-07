import AppKit
import SwiftUI

/// Borderless, non-activating panel used for HUDs, toasts, thumbnails and pins.
class FloatingPanel: NSPanel {
    var allowsKey: Bool

    init(level: NSWindow.Level = .statusBar, allowsKey: Bool = false, clickThrough: Bool = false) {
        self.allowsKey = allowsKey
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Before the level: making a panel floating resets its level to `.floating`.
        isFloatingPanel = true
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = clickThrough
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Hosts `view` and resizes the panel to its fitting size.
    @discardableResult
    func host<Content: View>(_ view: Content) -> NSHostingView<Content> {
        let hosting = NSHostingView(rootView: view)
        contentView = hosting
        setContentSize(hosting.fittingSize)
        return hosting
    }

    func fade(to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            animator().alphaValue = alpha
        }
    }
}

extension NSWindow.Level {
    /// Above the capture overlay (which uses `.screenSaver`).
    static let aboveOverlay = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    /// The recording controls, above the dimmed screen of the adjust stage (`.statusBar`).
    static let recordingControls = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
}
