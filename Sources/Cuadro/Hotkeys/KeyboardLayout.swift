import AppKit
import Carbon.HIToolbox
import CuadroKit

/// Keyboard-layout-aware key names and system shortcut lookups.
enum KeyboardLayout {
    /// Name of the key as printed on the current layout (e.g. "Z" on QWERTZ for key code 6).
    static func name(for keyCode: UInt32) -> String {
        if let special = KeyCombo.specialKeyName(for: keyCode) { return special }
        if let translated = translate(keyCode), !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return translated.uppercased()
        }
        return KeyCombo.keyName(for: keyCode)
    }

    static func displayString(for combo: KeyCombo) -> String {
        combo.displayString(keyName: name(for: combo.keyCode))
    }

    /// Lowercase character for an NSMenuItem key equivalent, when the key produces one.
    static func keyEquivalent(for keyCode: UInt32) -> String? {
        guard KeyCombo.specialKeyName(for: keyCode) == nil, let character = translate(keyCode) else { return nil }
        return character.lowercased()
    }

    private static func translate(_ keyCode: UInt32) -> String? {
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let source, let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length, &characters
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }

    /// Whether macOS itself uses `combo` (Screenshot, Mission Control, Spotlight, ...).
    static func isSystemShortcut(_ combo: KeyCombo) -> Bool {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let list = array?.takeRetainedValue() as? [[String: Any]] else {
            return false
        }
        for entry in list {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int
            else { continue }
            let system = KeyCombo(keyCode: UInt32(code), carbonModifiers: UInt32(modifiers))
            if system == combo { return true }
        }
        return false
    }
}
