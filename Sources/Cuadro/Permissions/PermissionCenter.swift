import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Where a permission stands for the running process.
enum PermissionState {
    case granted
    /// Allowed in System Settings, but macOS applies it only to a relaunched Cuadro (Screen Recording).
    case needsRelaunch
    case missing
}

/// Screen Recording (required) and Accessibility (auto-scroll only) permissions. Cuadro needs no
/// others: its global shortcuts are Carbon hot keys, which work without Input Monitoring.
final class PermissionCenter {
    static let shared = PermissionCenter()

    /// Bump when the welcome window gains a permission, so it shows once more after an update.
    static let onboardingVersion = 1

    /// Read when the app starts (the delegate touches `shared` first thing); a grant given later
    /// takes effect only after a relaunch.
    let hadScreenRecordingAtLaunch = CGPreflightScreenCaptureAccess()

    var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    var screenRecordingState: PermissionState {
        guard hasScreenRecording else { return .missing }
        return hadScreenRecordingAtLaunch ? .granted : .needsRelaunch
    }

    var canCapture: Bool { screenRecordingState == .granted }

    /// First launch (or a new onboarding version), or captures cannot work yet.
    var needsOnboarding: Bool {
        !canCapture || AppSettings.shared.completedOnboardingVersion < Self.onboardingVersion
    }

    /// Records that the user saw every permission while captures worked.
    func completeOnboarding() {
        guard canCapture else { return }
        AppSettings.shared.completedOnboardingVersion = Self.onboardingVersion
    }

    /// Shows the system prompt the first time; afterwards macOS only lists the app in Settings.
    @discardableResult
    func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Set once the user pressed Allow… for Screen Recording in this process.
    private(set) var didAskForScreenRecording = false
    private var clearedEntries = Set<String>()

    /// The Allow… button. After an update of an ad-hoc signed copy, System Settings still shows
    /// Cuadro switched on, but the entry belongs to the old signature and macOS ignores it. So
    /// the first press per launch clears Cuadro's own entry, then asks afresh. Later presses
    /// only ask: clearing again would undo a switch the user just turned on, which a running
    /// process cannot see until it relaunches.
    func allowScreenRecording() {
        clearEntry(for: "ScreenCapture")
        didAskForScreenRecording = true
        if !requestScreenRecording() {
            openScreenRecordingSettings()
        }
    }

    func allowAccessibility() {
        clearEntry(for: "Accessibility")
        requestAccessibility()
        openAccessibilitySettings()
    }

    /// `tccutil reset <service> <bundle id>`, once per service and launch; touches only Cuadro.
    private func clearEntry(for service: String) {
        guard let bundleID = Bundle.main.bundleIdentifier, clearedEntries.insert(service).inserted else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", service, bundleID]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                Log.app.error("tccutil reset \(service, privacy: .public) exited with \(task.terminationStatus)")
            }
        } catch {
            Log.app.error("tccutil reset \(service, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    var hasAccessibility: Bool { AXIsProcessTrusted() }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Asks for the microphone, which only recordings with the microphone use. True when allowed.
    /// Once refused, only System Settings can turn it on: `openingSettings` opens that pane.
    func requestMicrophone(openingSettings: Bool) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            if openingSettings {
                open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            }
            return false
        }
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
