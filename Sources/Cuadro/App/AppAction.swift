import CuadroKit
import Foundation

/// Everything that can be bound to a global shortcut or picked from the menu bar.
enum AppAction: String, CaseIterable, Identifiable, Codable {
    case captureArea
    case captureWindow
    case captureActiveWindow
    case captureFullscreen
    case captureScrolling
    case repeatArea
    case captureDelayed
    case recognizeText
    case pickColor
    case measure
    case openFile
    case openClipboard
    case recordScreen
    case recordScreenWithMicrophone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureWindow: "Capture Window"
        case .captureActiveWindow: "Capture Active Window"
        case .captureFullscreen: "Capture Full Screen"
        case .captureScrolling: "Scrolling Capture"
        case .repeatArea: "Repeat Last Area"
        case .captureDelayed: "Delayed Capture"
        case .recognizeText: "Recognize Text"
        case .pickColor: "Pick Color"
        case .measure: "Measure Screen"
        case .openFile: "Open Image…"
        case .openClipboard: "Open from Clipboard"
        case .recordScreen: "Record Screen"
        case .recordScreenWithMicrophone: "Record Screen with Microphone"
        }
    }

    var symbol: String {
        switch self {
        case .captureArea: "rectangle.dashed"
        case .captureWindow: "macwindow"
        case .captureActiveWindow: "macwindow.on.rectangle"
        case .captureFullscreen: "display"
        case .captureScrolling: "arrow.up.and.down.text.horizontal"
        case .repeatArea: "repeat"
        case .captureDelayed: "timer"
        case .recognizeText: "text.viewfinder"
        case .pickColor: "eyedropper"
        case .measure: "ruler"
        case .openFile: "folder"
        case .openClipboard: "doc.on.clipboard"
        case .recordScreen: "record.circle"
        case .recordScreenWithMicrophone: "mic.circle"
        }
    }

    /// Shottr-compatible defaults; everything else starts unassigned.
    var defaultShortcut: KeyCombo? {
        switch self {
        case .captureFullscreen: KeyCombo(keyCode: 0x12, modifiers: [.command, .shift])
        case .captureArea: KeyCombo(keyCode: 0x13, modifiers: [.command, .shift])
        default: nil
        }
    }

    static var defaultShortcuts: [AppAction: KeyCombo] {
        Dictionary(uniqueKeysWithValues: allCases.compactMap { action in action.defaultShortcut.map { (action, $0) } })
    }

    /// Takes a plain screenshot, so holding Control copies it without opening anything.
    var supportsCopyOnly: Bool {
        switch self {
        case .captureArea, .captureWindow, .captureActiveWindow, .captureFullscreen, .repeatArea, .captureDelayed: true
        default: false
        }
    }

    var hotKeyID: UInt32 { UInt32((Self.allCases.firstIndex(of: self) ?? 0) + 1) }

    init?(hotKeyID: UInt32) {
        let index = Int(hotKeyID) - 1
        guard Self.allCases.indices.contains(index) else { return nil }
        self = Self.allCases[index]
    }
}
