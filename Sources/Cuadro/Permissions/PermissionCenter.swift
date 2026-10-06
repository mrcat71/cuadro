import AppKit
import ApplicationServices
import CoreGraphics

/// Screen Recording (required) and Accessibility (auto-scroll only) permissions.
final class PermissionCenter {
    static let shared = PermissionCenter()

    var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards macOS only lists the app in Settings.
    @discardableResult
    func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    var hasAccessibility: Bool { AXIsProcessTrusted() }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// Restarts the app; macOS applies a new Screen Recording grant only to fresh processes.
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            Log.app.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
