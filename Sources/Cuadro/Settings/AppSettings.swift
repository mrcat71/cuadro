import AppKit
import CuadroKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum AfterCaptureAction: String, CaseIterable, Identifiable {
    case openEditor, showThumbnail, nothing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openEditor: "Open the editor"
        case .showThumbnail: "Show a floating thumbnail"
        case .nothing: "Nothing else"
        }
    }
}

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg, heic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }

    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }
}

/// Last captured area, for "Repeat Last Area".
struct StoredArea: Codable, Equatable {
    /// Cocoa global coordinates.
    var rect: CGRect
    var displayID: UInt32
}

/// User preferences backed by UserDefaults.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults: UserDefaults

    var afterCapture: AfterCaptureAction { didSet { defaults.set(afterCapture.rawValue, forKey: Keys.afterCapture) } }
    var copyToClipboard: Bool { didSet { defaults.set(copyToClipboard, forKey: Keys.copyToClipboard) } }
    var autoSave: Bool { didSet { defaults.set(autoSave, forKey: Keys.autoSave) } }
    var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: Keys.saveFolder) } }
    var fileNameTemplate: String { didSet { defaults.set(fileNameTemplate, forKey: Keys.fileNameTemplate) } }
    var imageFormat: ImageFormat { didSet { defaults.set(imageFormat.rawValue, forKey: Keys.imageFormat) } }
    var jpegQuality: Double { didSet { defaults.set(jpegQuality, forKey: Keys.jpegQuality) } }
    var downscaleRetina: Bool { didSet { defaults.set(downscaleRetina, forKey: Keys.downscaleRetina) } }
    var convertToSRGB: Bool { didSet { defaults.set(convertToSRGB, forKey: Keys.convertToSRGB) } }
    var playSound: Bool { didSet { defaults.set(playSound, forKey: Keys.playSound) } }
    var showCursor: Bool { didSet { defaults.set(showCursor, forKey: Keys.showCursor) } }
    var windowShadow: Bool { didSet { defaults.set(windowShadow, forKey: Keys.windowShadow) } }
    var showMagnifier: Bool { didSet { defaults.set(showMagnifier, forKey: Keys.showMagnifier) } }
    var delaySeconds: Int { didSet { defaults.set(delaySeconds, forKey: Keys.delaySeconds) } }
    var scrollMaxHeight: Int { didSet { defaults.set(scrollMaxHeight, forKey: Keys.scrollMaxHeight) } }
    var colorFormat: ColorFormat { didSet { defaults.set(colorFormat.rawValue, forKey: Keys.colorFormat) } }
    var showMenuBarIcon: Bool {
        didSet {
            defaults.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon)
            NotificationCenter.default.post(name: .menuBarIconVisibilityChanged, object: nil)
        }
    }
    var showDockIconWhileEditing: Bool { didSet { defaults.set(showDockIconWhileEditing, forKey: Keys.showDockIcon) } }
    var keepHistory: Bool { didSet { defaults.set(keepHistory, forKey: Keys.keepHistory) } }
    var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: Keys.historyLimit) } }
    var thumbnailSeconds: Double { didSet { defaults.set(thumbnailSeconds, forKey: Keys.thumbnailSeconds) } }
    var annotationShadows: Bool { didSet { defaults.set(annotationShadows, forKey: Keys.annotationShadows) } }
    var autoScrollSpeed: Double { didSet { defaults.set(autoScrollSpeed, forKey: Keys.autoScrollSpeed) } }
    var recordPointer: Bool { didSet { defaults.set(recordPointer, forKey: Keys.recordPointer) } }
    var recordClicks: Bool { didSet { defaults.set(recordClicks, forKey: Keys.recordClicks) } }
    var recordSystemAudio: Bool { didSet { defaults.set(recordSystemAudio, forKey: Keys.recordSystemAudio) } }
    /// Last onboarding version the user finished (0: never), see `PermissionCenter.onboardingVersion`.
    var completedOnboardingVersion: Int { didSet { defaults.set(completedOnboardingVersion, forKey: Keys.completedOnboardingVersion) } }

    private(set) var shortcuts: [AppAction: KeyCombo]
    private(set) var toolStyles: [String: AnnotationStyle]
    var lastArea: StoredArea? { didSet { store(lastArea, forKey: Keys.lastArea) } }
    var backdrop: Backdrop { didSet { store(backdrop, forKey: Keys.backdrop) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        afterCapture = AfterCaptureAction(rawValue: defaults.string(forKey: Keys.afterCapture) ?? "") ?? .openEditor
        copyToClipboard = defaults.object(forKey: Keys.copyToClipboard) as? Bool ?? true
        autoSave = defaults.object(forKey: Keys.autoSave) as? Bool ?? false
        let picturesFolder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        saveFolder = defaults.string(forKey: Keys.saveFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? picturesFolder.appendingPathComponent("Screenshots", isDirectory: true)
        fileNameTemplate = defaults.string(forKey: Keys.fileNameTemplate) ?? FileNameTemplate.defaultTemplate
        imageFormat = ImageFormat(rawValue: defaults.string(forKey: Keys.imageFormat) ?? "") ?? .png
        jpegQuality = defaults.object(forKey: Keys.jpegQuality) as? Double ?? 0.9
        downscaleRetina = defaults.object(forKey: Keys.downscaleRetina) as? Bool ?? false
        convertToSRGB = defaults.object(forKey: Keys.convertToSRGB) as? Bool ?? false
        playSound = defaults.object(forKey: Keys.playSound) as? Bool ?? true
        showCursor = defaults.object(forKey: Keys.showCursor) as? Bool ?? false
        windowShadow = defaults.object(forKey: Keys.windowShadow) as? Bool ?? true
        showMagnifier = defaults.object(forKey: Keys.showMagnifier) as? Bool ?? true
        delaySeconds = defaults.object(forKey: Keys.delaySeconds) as? Int ?? 3
        scrollMaxHeight = defaults.object(forKey: Keys.scrollMaxHeight) as? Int ?? 20_000
        colorFormat = ColorFormat(rawValue: defaults.string(forKey: Keys.colorFormat) ?? "") ?? .hex
        showMenuBarIcon = defaults.object(forKey: Keys.showMenuBarIcon) as? Bool ?? true
        showDockIconWhileEditing = defaults.object(forKey: Keys.showDockIcon) as? Bool ?? true
        keepHistory = defaults.object(forKey: Keys.keepHistory) as? Bool ?? true
        historyLimit = defaults.object(forKey: Keys.historyLimit) as? Int ?? 30
        thumbnailSeconds = defaults.object(forKey: Keys.thumbnailSeconds) as? Double ?? 6
        annotationShadows = defaults.object(forKey: Keys.annotationShadows) as? Bool ?? true
        autoScrollSpeed = defaults.object(forKey: Keys.autoScrollSpeed) as? Double ?? 1
        recordPointer = defaults.object(forKey: Keys.recordPointer) as? Bool ?? true
        recordClicks = defaults.object(forKey: Keys.recordClicks) as? Bool ?? true
        recordSystemAudio = defaults.object(forKey: Keys.recordSystemAudio) as? Bool ?? false
        completedOnboardingVersion = defaults.integer(forKey: Keys.completedOnboardingVersion)
        shortcuts = Self.loadShortcuts(from: defaults)
        toolStyles = Self.load([String: AnnotationStyle].self, from: defaults, key: Keys.toolStyles) ?? [:]
        lastArea = Self.load(StoredArea.self, from: defaults, key: Keys.lastArea)
        backdrop = Self.load(Backdrop.self, from: defaults, key: Keys.backdrop) ?? Backdrop()
    }

    // MARK: Shortcuts

    func setShortcut(_ combo: KeyCombo?, for action: AppAction) {
        if let combo {
            // One combo can only trigger one action.
            for (other, existing) in shortcuts where existing == combo && other != action {
                shortcuts[other] = nil
            }
        }
        shortcuts[action] = combo
        saveShortcuts()
    }

    func resetShortcuts() {
        shortcuts = AppAction.defaultShortcuts
        saveShortcuts()
    }

    private func saveShortcuts() {
        let raw = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        store(raw, forKey: Keys.shortcuts)
        HotKeyCenter.shared.apply(shortcuts)
    }

    private static func loadShortcuts(from defaults: UserDefaults) -> [AppAction: KeyCombo] {
        guard let raw = load([String: KeyCombo].self, from: defaults, key: Keys.shortcuts) else {
            return AppAction.defaultShortcuts
        }
        var result: [AppAction: KeyCombo] = [:]
        for (key, combo) in raw {
            if let action = AppAction(rawValue: key) { result[action] = combo }
        }
        return result
    }

    // MARK: Tool styles

    func style(for key: String) -> AnnotationStyle? { toolStyles[key] }

    func setStyle(_ style: AnnotationStyle, for key: String) {
        toolStyles[key] = style
        store(toolStyles, forKey: Keys.toolStyles)
    }

    func resetToolStyles() {
        toolStyles = [:]
        defaults.removeObject(forKey: Keys.toolStyles)
    }

    /// Increments and returns the `{n}` file name counter.
    func nextFileCounter() -> Int {
        let next = defaults.integer(forKey: Keys.fileCounter) + 1
        defaults.set(next, forKey: Keys.fileCounter)
        return next
    }

    // MARK: Storage helpers

    private func store<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            Log.app.error("Failed to store setting \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Log.app.error("Ignoring unreadable setting \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private enum Keys {
        static let afterCapture = "afterCapture"
        static let copyToClipboard = "copyToClipboard"
        static let autoSave = "autoSave"
        static let saveFolder = "saveFolder"
        static let fileNameTemplate = "fileNameTemplate"
        static let imageFormat = "imageFormat"
        static let jpegQuality = "jpegQuality"
        static let downscaleRetina = "downscaleRetina"
        static let convertToSRGB = "convertToSRGB"
        static let playSound = "playSound"
        static let showCursor = "showCursor"
        static let windowShadow = "windowShadow"
        static let showMagnifier = "showMagnifier"
        static let delaySeconds = "delaySeconds"
        static let scrollMaxHeight = "scrollMaxHeight"
        static let colorFormat = "colorFormat"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showDockIcon = "showDockIconWhileEditing"
        static let keepHistory = "keepHistory"
        static let historyLimit = "historyLimit"
        static let thumbnailSeconds = "thumbnailSeconds"
        static let annotationShadows = "annotationShadows"
        static let autoScrollSpeed = "autoScrollSpeed"
        static let recordPointer = "recordPointer"
        static let recordClicks = "recordClicks"
        static let recordSystemAudio = "recordSystemAudio"
        static let completedOnboardingVersion = "completedOnboardingVersion"
        static let shortcuts = "shortcuts"
        static let toolStyles = "toolStyles"
        static let lastArea = "lastArea"
        static let backdrop = "backdrop"
        static let fileCounter = "fileCounter"
    }
}
