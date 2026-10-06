import Foundation

/// A global keyboard shortcut: a virtual key code plus modifiers.
public struct KeyCombo: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    // Carbon modifier masks (cmdKey, shiftKey, optionKey, controlKey from HIToolbox/Events.h).
    public static let carbonCommand: UInt32 = 1 << 8
    public static let carbonShift: UInt32 = 1 << 9
    public static let carbonOption: UInt32 = 1 << 11
    public static let carbonControl: UInt32 = 1 << 12

    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        var modifiers: Modifiers = []
        if carbonModifiers & Self.carbonControl != 0 { modifiers.insert(.control) }
        if carbonModifiers & Self.carbonOption != 0 { modifiers.insert(.option) }
        if carbonModifiers & Self.carbonShift != 0 { modifiers.insert(.shift) }
        if carbonModifiers & Self.carbonCommand != 0 { modifiers.insert(.command) }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    public var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.control) { value |= Self.carbonControl }
        if modifiers.contains(.option) { value |= Self.carbonOption }
        if modifiers.contains(.shift) { value |= Self.carbonShift }
        if modifiers.contains(.command) { value |= Self.carbonCommand }
        return value
    }

    /// Modifier glyphs in the standard macOS order.
    public var modifierSymbols: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text
    }

    /// Global shortcuts need Command, Control or Option, except function keys.
    public var isValidGlobalShortcut: Bool {
        if Self.functionKeyCodes.contains(keyCode) { return true }
        return !modifiers.isDisjoint(with: [.command, .control, .option])
    }

    /// `keyName` comes from the current keyboard layout; falls back to known names.
    public func displayString(keyName: String? = nil) -> String {
        modifierSymbols + (keyName ?? Self.keyName(for: keyCode))
    }

    public static func keyName(for keyCode: UInt32) -> String {
        specialKeyNames[keyCode] ?? ansiKeyNames[keyCode] ?? "Key \(keyCode)"
    }

    public static func specialKeyName(for keyCode: UInt32) -> String? {
        specialKeyNames[keyCode]
    }

    public static let functionKeyCodes: Set<UInt32> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
    ]

    static let specialKeyNames: [UInt32: String] = [
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋", 0x75: "⌦",
        0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18",
        0x50: "F19", 0x5A: "F20",
    ]

    /// US ANSI layout names, used when the current layout cannot be queried.
    static let ansiKeyNames: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
        0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y",
        0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O", 0x20: "U",
        0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
    ]
}
