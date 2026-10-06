import AppKit
import ServiceManagement
import SwiftUI

/// Native toolbar-style Settings window hosting SwiftUI panes.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        Self.add(to: tabs, "General", "gearshape", GeneralSettingsPane())
        Self.add(to: tabs, "Capture", "camera.viewfinder", CaptureSettingsPane())
        Self.add(to: tabs, "Output", "square.and.arrow.down", OutputSettingsPane())
        Self.add(to: tabs, "Shortcuts", "keyboard", ShortcutsSettingsPane())
        Self.add(to: tabs, "Editor", "pencil.and.scribble", EditorSettingsPane())
        Self.add(to: tabs, "About", "info.circle", AboutSettingsPane())
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func add<Content: View>(to tabs: NSTabViewController, _ title: String, _ symbol: String, _ view: Content) {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabs.addTabViewItem(item)
    }

    func show() {
        guard let window else { return }
        DockPresence.shared.track(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

enum LoginItem {
    /// On also while macOS waits for approval in Login Items, so the toggle does not flip back.
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    static func set(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    ToastCenter.shared.show("Approve Cuadro in Login Items", detail: "System Settings > General > Login Items", style: .info, duration: 4)
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            ToastCenter.shared.showError("Could not change the login item", error)
        }
    }
}
