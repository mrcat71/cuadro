import AppKit

/// Shows the Dock icon and main menu while editor or settings windows are open, or an update
/// is on screen, and goes back to a menu bar only app when they close.
final class DockPresence {
    static let shared = DockPresence()

    private var windows: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Set while Sparkle shows an update, so its window is not lost behind other apps.
    var isShowingUpdate = false {
        didSet { update() }
    }

    func track(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard windows[id] == nil else {
            update()
            return
        }
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.untrack(id)
            }
        }
        windows[id] = token
        update()
    }

    func update() {
        let editing = !windows.isEmpty && AppSettings.shared.showDockIconWhileEditing
        let policy: NSApplication.ActivationPolicy = editing || isShowingUpdate ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    private func untrack(_ id: ObjectIdentifier) {
        if let token = windows.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(token)
        }
        // Let the window finish closing before the app possibly loses its Dock icon.
        Task { @MainActor in self.update() }
    }
}
