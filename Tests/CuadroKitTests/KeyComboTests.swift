import Testing
@testable import CuadroKit

struct KeyComboTests {
    @Test(arguments: [
        (KeyCombo.Modifiers([.command, .shift]), "⇧⌘"),
        (KeyCombo.Modifiers([.control, .option, .shift, .command]), "⌃⌥⇧⌘"),
        (KeyCombo.Modifiers([.option]), "⌥"),
        (KeyCombo.Modifiers([]), ""),
    ])
    func modifierSymbols(modifiers: KeyCombo.Modifiers, expected: String) {
        #expect(KeyCombo(keyCode: 0, modifiers: modifiers).modifierSymbols == expected)
    }

    @Test(arguments: [
        KeyCombo.Modifiers([.command]),
        KeyCombo.Modifiers([.command, .shift]),
        KeyCombo.Modifiers([.control, .option]),
        KeyCombo.Modifiers([.control, .option, .shift, .command]),
    ])
    func carbonRoundTrip(modifiers: KeyCombo.Modifiers) {
        let combo = KeyCombo(keyCode: 0x13, modifiers: modifiers)
        #expect(KeyCombo(keyCode: 0x13, carbonModifiers: combo.carbonModifiers) == combo)
    }

    @Test func carbonMasksMatchHIToolbox() {
        #expect(KeyCombo(keyCode: 0, modifiers: [.command, .shift]).carbonModifiers == 256 | 512)
        #expect(KeyCombo(keyCode: 0, modifiers: [.option, .control]).carbonModifiers == 2048 | 4096)
    }

    @Test(arguments: [
        (KeyCombo(keyCode: 0x00, modifiers: [.shift]), false),
        (KeyCombo(keyCode: 0x00, modifiers: []), false),
        (KeyCombo(keyCode: 0x13, modifiers: [.command, .shift]), true),
        (KeyCombo(keyCode: 0x60, modifiers: []), true),
        (KeyCombo(keyCode: 0x12, modifiers: [.control]), true),
    ])
    func globalShortcutValidity(combo: KeyCombo, valid: Bool) {
        #expect(combo.isValidGlobalShortcut == valid)
    }

    @Test func displayStrings() {
        #expect(KeyCombo(keyCode: 0x13, modifiers: [.command, .shift]).displayString() == "⇧⌘2")
        #expect(KeyCombo(keyCode: 0x31, modifiers: [.option]).displayString() == "⌥Space")
        #expect(KeyCombo(keyCode: 0x7A, modifiers: []).displayString() == "F1")
        #expect(KeyCombo(keyCode: 0x08, modifiers: [.control]).displayString(keyName: "С") == "⌃С")
    }
}
