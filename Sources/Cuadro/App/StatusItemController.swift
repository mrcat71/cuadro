import AppKit
import CuadroKit

/// Menu bar icon and its menu.
final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var observer: NSObjectProtocol?
    private var recordingObserver: NSObjectProtocol?
    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    override init() {
        super.init()
        menu.delegate = self
        updateVisibility()
        observer = NotificationCenter.default.addObserver(forName: .menuBarIconVisibilityChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        recordingObserver = NotificationCenter.default.addObserver(forName: .recordingChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIcon() }
        }
    }

    private func updateVisibility() {
        if AppSettings.shared.showMenuBarIcon {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.toolTip = "Cuadro"
            item.menu = menu
            statusItem = item
            updateIcon()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    /// A red record symbol while a screen recording runs.
    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let recording = CaptureCoordinator.shared.isRecording
        let image = NSImage(systemSymbolName: recording ? "record.circle" : "viewfinder", accessibilityDescription: recording ? "Cuadro, recording" : "Cuadro")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = recording ? .systemRed : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let elapsed = CaptureCoordinator.shared.recordingElapsed {
            let stop = NSMenuItem.action("Stop Recording (\(RecordingHUDView.format(elapsed)))") { CaptureCoordinator.shared.toggleRecording() }
            menu.addItem(stop.with(symbol: "stop.circle"))
            menu.addItem(.separator())
        }
        let screenRecording = PermissionCenter.shared.screenRecordingState
        if screenRecording != .granted {
            let title = screenRecording == .needsRelaunch ? "Relaunch to Finish Setup…" : "Allow Screen Recording…"
            menu.addItem(NSMenuItem.action(title) { OnboardingWindowController.shared.show() }.with(symbol: "exclamationmark.triangle"))
            menu.addItem(.separator())
        }
        for action in [AppAction.captureArea, .captureWindow, .captureActiveWindow, .captureFullscreen, .captureScrolling, .repeatArea] {
            menu.addItem(item(for: action))
        }
        menu.addItem(delayedItem())
        menu.addItem(NSMenuItem.action("Pin Area to Screen") { CaptureCoordinator.shared.pinArea() }.with(symbol: "pin"))
        menu.addItem(item(for: .recordScreen))
        menu.addItem(.separator())
        for action in [AppAction.recognizeText, .pickColor, .measure] {
            menu.addItem(item(for: action))
        }
        menu.addItem(.separator())
        for action in [AppAction.openFile, .openClipboard] {
            menu.addItem(item(for: action))
        }
        menu.addItem(recentItem())
        if !PinWindowController.pins.isEmpty {
            menu.addItem(pinsItem())
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.action("Settings…", keyEquivalent: ",") { SettingsWindowController.shared.show() })
        menu.addItem(NSMenuItem.action("About Cuadro") {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        })
        if Updater.shared.isAvailable {
            // Targets the app delegate, which disables it while a check is running.
            menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem.action("Quit Cuadro", keyEquivalent: "q") { NSApp.terminate(nil) })
    }

    private func item(for action: AppAction) -> NSMenuItem {
        let title = action == .recordScreen && CaptureCoordinator.shared.isRecording ? "Stop Recording" : action.title
        let item = NSMenuItem.action(title) {
            CaptureCoordinator.shared.perform(action, copyOnly: NSEvent.modifierFlags.contains(.control))
        }
        item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        if let combo = AppSettings.shared.shortcuts[action], let key = KeyboardLayout.keyEquivalent(for: combo.keyCode) {
            item.keyEquivalent = key
            var flags: NSEvent.ModifierFlags = []
            if combo.modifiers.contains(.command) { flags.insert(.command) }
            if combo.modifiers.contains(.shift) { flags.insert(.shift) }
            if combo.modifiers.contains(.option) { flags.insert(.option) }
            if combo.modifiers.contains(.control) { flags.insert(.control) }
            item.keyEquivalentModifierMask = flags
        }
        return item
    }

    private func delayedItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Delayed Capture", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        let submenu = NSMenu()
        for seconds in [3, 5, 10] {
            submenu.addItem(NSMenuItem.action("In \(seconds) Seconds") {
                CaptureCoordinator.shared.captureDelayed(seconds: seconds, copyOnly: NSEvent.modifierFlags.contains(.control))
            })
        }
        item.submenu = submenu
        return item
    }

    private func recentItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        let submenu = NSMenu()
        let entries = HistoryStore.shared.entries.prefix(12)
        if entries.isEmpty {
            let empty = NSMenuItem(title: "No Captures Yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for entry in entries {
            let title = "\(relativeFormatter.localizedString(for: entry.date, relativeTo: Date()))  \(entry.width) × \(entry.height)"
            let recent = NSMenuItem.action(title) {
                guard let image = HistoryStore.shared.image(for: entry) else {
                    ToastCenter.shared.show("That capture is gone", style: .warning)
                    return
                }
                EditorWindowController.open(CaptureResult(image: image.image, scale: image.scale, kind: .file, title: "Recent Capture"))
            }
            if let thumbnail = HistoryStore.shared.thumbnail(for: entry) {
                let size = thumbnail.size
                let factor = min(40 / max(size.width, 1), 26 / max(size.height, 1))
                thumbnail.size = NSSize(width: size.width * factor, height: size.height * factor)
                recent.image = thumbnail
            }
            submenu.addItem(recent)
        }
        if !entries.isEmpty {
            submenu.addItem(.separator())
            submenu.addItem(NSMenuItem.action("Clear History") { HistoryStore.shared.clear() })
        }
        item.submenu = submenu
        return item
    }

    private func pinsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Pinned Images", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        let submenu = NSMenu()
        for pin in PinWindowController.pins {
            let entry = NSMenuItem(title: pin.title, action: nil, keyEquivalent: "")
            let actions = NSMenu()
            actions.addItem(NSMenuItem.action("Bring to Front") { pin.window?.orderFrontRegardless() })
            actions.addItem(NSMenuItem.action(pin.isLocked ? "Unlock Clicks" : "Lock (Click Through)") { pin.setLocked(!pin.isLocked) })
            actions.addItem(NSMenuItem.action("Close") { pin.close() })
            entry.submenu = actions
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(NSMenuItem.action("Close All Pins") { PinWindowController.closeAll() })
        item.submenu = submenu
        return item
    }
}

extension NSMenuItem {
    func with(symbol: String) -> Self {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return self
    }
}
