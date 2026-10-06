import AppKit
import CuadroKit
import UniformTypeIdentifiers

/// Saving to the screenshots folder and via the save panel.
enum SaveService {
    /// Saves into the configured folder with the file name template. Returns the file URL.
    @discardableResult
    static func quickSave(_ image: CGImage, scale: CGFloat, appName: String? = nil) throws -> URL {
        let settings = AppSettings.shared
        let folder = settings.saveFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prepared = ImageExporter.prepared(image, scale: scale)
        let name = FileNameTemplate.render(
            settings.fileNameTemplate,
            context: .init(width: prepared.image.width, height: prepared.image.height, appName: appName, counter: settings.nextFileCounter())
        )
        let url = FileNameTemplate.uniqueFileURL(directory: folder, baseName: name, pathExtension: settings.imageFormat.fileExtension) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard let data = ImageExporter.data(for: prepared.image, format: settings.imageFormat, scale: prepared.scale) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        try data.write(to: url, options: .atomic)
        Log.output.info("Saved \(url.path, privacy: .public)")
        return url
    }

    /// Same as `quickSave`, with encoding and file I/O off the main actor.
    static func quickSaveInBackground(_ image: CGImage, scale: CGFloat, appName: String? = nil) async throws -> URL {
        let settings = AppSettings.shared
        let folder = settings.saveFolder
        let template = settings.fileNameTemplate
        let counter = settings.nextFileCounter()
        let downscale = settings.downscaleRetina
        let format = settings.imageFormat
        let fileExtension = format.fileExtension
        let typeIdentifier = format.type.identifier
        let quality: Double? = format == .png ? nil : settings.jpegQuality
        let flatten = format == .jpeg
        let url = try await Task.detached(priority: .utility) { () throws -> URL in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let prepared = ImageExporter.prepare(image, scale: scale, downscale: downscale)
            let name = FileNameTemplate.render(
                template,
                context: .init(width: prepared.image.width, height: prepared.image.height, appName: appName, counter: counter)
            )
            let url = FileNameTemplate.uniqueFileURL(directory: folder, baseName: name, pathExtension: fileExtension) {
                FileManager.default.fileExists(atPath: $0.path)
            }
            guard let data = ImageExporter.encode(prepared.image, typeIdentifier: typeIdentifier, scale: prepared.scale, quality: quality, flatten: flatten) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            try data.write(to: url, options: .atomic)
            return url
        }.value
        Log.output.info("Saved \(url.path, privacy: .public)")
        return url
    }

    /// Shows a save panel with a format picker, attached to `window` when given.
    static func saveAs(_ image: CGImage, scale: CGFloat, suggestedName: String, window: NSWindow?) {
        let settings = AppSettings.shared
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = settings.saveFolder
        panel.canCreateDirectories = true
        let chooser = FormatChooser(format: settings.imageFormat, panel: panel)
        panel.accessoryView = chooser.view
        panel.allowedContentTypes = [settings.imageFormat.type]

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let prepared = ImageExporter.prepared(image, scale: scale)
            guard let data = ImageExporter.data(for: prepared.image, format: chooser.format, scale: prepared.scale) else {
                ToastCenter.shared.show("Could not encode the image", style: .failure)
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                ToastCenter.shared.show("Saved", detail: url.lastPathComponent)
            } catch {
                ToastCenter.shared.showError("Could not save", error)
            }
            _ = chooser
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }
}

/// Format popup shown in the save panel.
final class FormatChooser: NSObject {
    private(set) var format: ImageFormat
    let view: NSView
    private weak var panel: NSSavePanel?
    private let popup = NSPopUpButton()

    init(format: ImageFormat, panel: NSSavePanel) {
        self.format = format
        self.panel = panel
        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view = stack
        super.init()
        for item in ImageFormat.allCases {
            popup.addItem(withTitle: item.title)
        }
        popup.selectItem(at: ImageFormat.allCases.firstIndex(of: format) ?? 0)
        popup.target = self
        popup.action = #selector(changed)
    }

    @objc private func changed() {
        format = ImageFormat.allCases[popup.indexOfSelectedItem]
        panel?.allowedContentTypes = [format.type]
    }
}
