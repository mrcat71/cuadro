import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = AppMenu.build()
        ImageExporter.removeStaleTemporaryFiles()
        statusItem = StatusItemController()
        HotKeyCenter.shared.handler = { action in
            CaptureCoordinator.shared.perform(action)
        }
        HotKeyCenter.shared.apply(AppSettings.shared.shortcuts)

        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--ui-snapshot"), arguments.indices.contains(index + 1) {
            UISnapshotRunner.run(outputDirectory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
            return
        }
        if !PermissionCenter.shared.hasScreenRecording {
            OnboardingWindowController.shared.show()
        }
        Log.app.notice("Cuadro started")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            SettingsWindowController.shared.show()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { DocumentOpener.open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Menu actions

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc func showHelp(_ sender: Any?) {
        if let url = URL(string: "https://github.com/mrcat71/cuadro#readme") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func performAppAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = AppAction(rawValue: raw) else { return }
        CaptureCoordinator.shared.perform(action)
    }

    @objc func openImageFile(_ sender: Any?) {
        DocumentOpener.openFile()
    }

    @objc func openFromClipboard(_ sender: Any?) {
        DocumentOpener.openClipboard()
    }
}
