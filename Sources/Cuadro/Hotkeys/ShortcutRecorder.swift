import AppKit
import CuadroKit
import SwiftUI

/// Captures the next key combination typed while recording.
@Observable
final class ShortcutRecorderModel {
    var isRecording = false
    var message: String?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var onRecord: ((KeyCombo?) -> Void)?

    func start(onRecord: @escaping (KeyCombo?) -> Void) {
        guard !isRecording else { return }
        self.onRecord = onRecord
        isRecording = true
        message = nil
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            self.handle(event)
            return nil
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onRecord = nil
        HotKeyCenter.shared.resume()
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyCombo.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        let keyCode = UInt32(event.keyCode)

        if modifiers.isEmpty, keyCode == 0x35 { // Escape cancels
            stop()
            return
        }
        if modifiers.isEmpty, keyCode == 0x33 || keyCode == 0x75 { // Delete clears
            onRecord?(nil)
            stop()
            return
        }
        let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)
        guard combo.isValidGlobalShortcut else {
            message = "Add ⌘, ⌃ or ⌥ to the shortcut."
            NSSound.beep()
            return
        }
        if KeyboardLayout.isSystemShortcut(combo) {
            message = "\(KeyboardLayout.displayString(for: combo)) is used by macOS. Free it in System Settings > Keyboard > Keyboard Shortcuts first."
            NSSound.beep()
            return
        }
        onRecord?(combo)
        stop()
    }
}

/// Settings row control showing a shortcut and recording a new one on click.
struct ShortcutRecorder: View {
    let action: AppAction
    @Bindable var settings: AppSettings
    @State private var recorder = ShortcutRecorderModel()

    private var combo: KeyCombo? { settings.shortcuts[action] }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    if recorder.isRecording {
                        recorder.stop()
                    } else {
                        recorder.start { combo in
                            settings.setShortcut(combo, for: action)
                        }
                    }
                } label: {
                    Text(label)
                        .monospacedDigit()
                        .foregroundStyle(recorder.isRecording ? Color.accentColor : (combo == nil ? .secondary : .primary))
                        .frame(minWidth: 110)
                }
                .buttonStyle(.bordered)
                .help(recorder.isRecording ? "Type a shortcut. Esc cancels, Delete clears." : "Click to record a shortcut")

                if combo != nil, !recorder.isRecording {
                    Button {
                        settings.setShortcut(nil, for: action)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove shortcut")
                }
            }
            if let message = recorder.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260, alignment: .trailing)
            } else if let status = HotKeyCenter.shared.failures[action], combo != nil {
                Text(verbatim: "Unavailable (in use by another app, \(status))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear { recorder.stop() }
    }

    private var label: String {
        if recorder.isRecording { return "Type shortcut…" }
        guard let combo else { return "Record Shortcut" }
        return KeyboardLayout.displayString(for: combo)
    }
}
