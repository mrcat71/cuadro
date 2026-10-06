import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Clipboard helpers.
enum Pasteboard {
    /// Copies an image as PNG plus TIFF (for older apps), honoring the 1x setting.
    @discardableResult
    static func copy(image: CGImage, scale: CGFloat) -> Bool {
        let prepared = ImageExporter.prepared(image, scale: scale)
        guard let png = ImageExporter.encodePNG(prepared.image, scale: prepared.scale) else {
            Log.output.error("PNG encoding failed for clipboard copy")
            return false
        }
        return write(png: png, image: prepared.image, scale: prepared.scale)
    }

    /// Encodes off the main actor, then copies unless the clipboard changed in the meantime
    /// (for example because the user already copied an edited version).
    static func copyInBackground(image: CGImage, scale: CGFloat) async -> Bool {
        let downscale = AppSettings.shared.downscaleRetina
        let changeCount = NSPasteboard.general.changeCount
        let encoded = await Task.detached(priority: .userInitiated) { () -> (png: Data, image: CGImage, scale: CGFloat)? in
            let prepared = ImageExporter.prepare(image, scale: scale, downscale: downscale)
            guard let png = ImageExporter.encodePNG(prepared.image, scale: prepared.scale) else { return nil }
            return (png, prepared.image, prepared.scale)
        }.value
        guard let encoded else {
            Log.output.error("PNG encoding failed for clipboard copy")
            return false
        }
        guard NSPasteboard.general.changeCount == changeCount else { return false }
        return write(png: encoded.png, image: encoded.image, scale: encoded.scale)
    }

    private static func write(png: Data, image: CGImage, scale: CGFloat) -> Bool {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        // TIFF is only encoded if an app actually asks for it.
        let provider = TIFFProvider(image: image, scale: scale)
        item.setDataProvider(provider, forTypes: [.tiff])
        tiffProvider = provider
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    /// Keeps the provider of the current clipboard item alive.
    private static var tiffProvider: TIFFProvider?

    static func copy(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static var hasImage: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// Image on the clipboard with its scale guessed from DPI metadata.
    static func image() -> (image: CGImage, scale: CGFloat)? {
        let pasteboard = NSPasteboard.general
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let decoded = decode(data) {
                return decoded
            }
        }
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL])?.first,
           let decoded = decode(url: url) {
            return decoded
        }
        if let image = NSImage(pasteboard: pasteboard), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return (cgImage, CGFloat(cgImage.width) / max(image.size.width, 1))
        }
        return nil
    }

    static func decode(_ data: Data) -> (image: CGImage, scale: CGFloat)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decode(source: source)
    }

    static func decode(url: URL) -> (image: CGImage, scale: CGFloat)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return decode(source: source)
    }

    private static func decode(source: CGImageSource) -> (image: CGImage, scale: CGFloat)? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        let scale = max(1, (dpi / 72).rounded())
        return (image, CGFloat(scale))
    }
}

/// Lazily encodes TIFF for apps that do not read PNG from the clipboard.
nonisolated final class TIFFProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let image: CGImage
    private let scale: CGFloat

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff else { return }
        let representation = NSBitmapImageRep(cgImage: image)
        representation.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        if let data = representation.tiffRepresentation {
            item.setData(data, forType: .tiff)
        }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}
