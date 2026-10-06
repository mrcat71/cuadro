import AppKit
import Carbon.HIToolbox
import CuadroKit

/// Signature of Cuadro's hot keys ('CUAD').
nonisolated let hotKeySignature: OSType = 0x4355_4144

/// Registers global shortcuts with the Carbon hot key API (no Accessibility permission needed).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// Called with the action and whether it came from the shortcut's Control variant.
    var handler: ((AppAction, _ copyOnly: Bool) -> Void)?
    /// Actions whose shortcut could not be registered (usually taken by another app).
    private(set) var failures: [AppAction: OSStatus] = [:]

    private var references: [AppAction: EventHotKeyRef] = [:]
    private var copyOnlyReferences: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var bindings: [AppAction: KeyCombo] = [:]
    private var suspendCount = 0

    func apply(_ bindings: [AppAction: KeyCombo]) {
        self.bindings = bindings
        registerAll()
    }

    /// Temporarily releases all shortcuts, e.g. while recording a new one.
    func suspend() {
        suspendCount += 1
        unregisterAll()
    }

    func resume() {
        suspendCount = max(0, suspendCount - 1)
        if suspendCount == 0 { registerAll() }
    }

    /// Hot key IDs above this are the Control variants of shortcuts (copy to the clipboard only).
    private static let copyOnlyOffset: UInt32 = 1000

    fileprivate func handle(id: UInt32) {
        let copyOnly = id > Self.copyOnlyOffset
        guard let action = AppAction(hotKeyID: copyOnly ? id - Self.copyOnlyOffset : id) else { return }
        handler?(action, copyOnly)
    }

    private func registerAll() {
        installHandlerIfNeeded()
        unregisterAll()
        failures = [:]
        guard suspendCount == 0 else { return }
        for (action, combo) in bindings {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: hotKeySignature, id: action.hotKeyID)
            let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                references[action] = reference
            } else {
                failures[action] = status
                Log.hotkeys.error("Could not register \(combo.displayString(), privacy: .public) for \(action.rawValue, privacy: .public): OSStatus \(status)")
            }
            registerCopyOnlyVariant(of: combo, for: action)
        }
        let registered = references.keys.map(\.rawValue).sorted().joined(separator: ", ")
        Log.hotkeys.notice("Registered \(self.references.count) hot keys: \(registered, privacy: .public)")
    }

    /// The same shortcut with Control added copies the screenshot without opening anything, like
    /// macOS's own Control-Shift-Command-3. Best effort: another app may own that combination.
    private func registerCopyOnlyVariant(of combo: KeyCombo, for action: AppAction) {
        guard action.supportsCopyOnly, !combo.modifiers.contains(.control) else { return }
        let variant = KeyCombo(keyCode: combo.keyCode, modifiers: combo.modifiers.union(.control))
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: hotKeySignature, id: action.hotKeyID + Self.copyOnlyOffset)
        let status = RegisterEventHotKey(variant.keyCode, variant.carbonModifiers, id, GetApplicationEventTarget(), 0, &reference)
        if status == noErr, let reference {
            copyOnlyReferences.append(reference)
        } else {
            Log.hotkeys.notice("Control variant \(variant.displayString(), privacy: .public) for \(action.rawValue, privacy: .public) is taken: OSStatus \(status)")
        }
    }

    private func unregisterAll() {
        for reference in references.values + copyOnlyReferences {
            UnregisterEventHotKey(reference)
        }
        references.removeAll()
        copyOnlyReferences.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, &eventHandler)
        if status != noErr {
            Log.hotkeys.error("InstallEventHandler failed: OSStatus \(status)")
        }
    }
}

private nonisolated func hotKeyEventHandler(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
    let id = hotKeyID.id
    // Carbon delivers application events on the main thread.
    MainActor.assumeIsolated {
        HotKeyCenter.shared.handle(id: id)
    }
    return noErr
}
