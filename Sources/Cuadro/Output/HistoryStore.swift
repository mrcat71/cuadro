import AppKit
import CuadroKit
import ImageIO

/// Recent captures kept in Application Support for the "Recent Captures" menu.
final class HistoryStore {
    static let shared = HistoryStore()

    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        let date: Date
        let fileName: String
        let width: Int
        let height: Int
        let scale: Double
    }

    private(set) var entries: [Entry] = []
    private var thumbnails: [UUID: NSImage] = [:]
    private let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        directory = support.appendingPathComponent("Cuadro/History", isDirectory: true)
        loadIndex()
    }

    func add(_ image: CGImage, scale: CGFloat) {
        let settings = AppSettings.shared
        guard settings.keepHistory else { return }
        let entry = Entry(id: UUID(), date: Date(), fileName: "\(UUID().uuidString).png", width: image.width, height: image.height, scale: Double(scale))
        let url = directory.appendingPathComponent(entry.fileName)
        let directory = self.directory
        Task {
            let written = await Task.detached(priority: .utility) { () -> Error? in
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    guard let data = ImageExporter.encodePNG(image, scale: scale) else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: url, options: .atomic)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let written {
                Log.output.error("History write failed: \(written.localizedDescription, privacy: .public)")
                return
            }
            entries.insert(entry, at: 0)
            trim(to: settings.historyLimit)
            saveIndex()
            NotificationCenter.default.post(name: .historyChanged, object: nil)
        }
    }

    func image(for entry: Entry) -> (image: CGImage, scale: CGFloat)? {
        guard let decoded = Pasteboard.decode(url: directory.appendingPathComponent(entry.fileName)) else { return nil }
        return (decoded.image, CGFloat(entry.scale))
    }

    func thumbnail(for entry: Entry, maxPixel: Int = 64) -> NSImage? {
        if let cached = thumbnails[entry.id] { return cached }
        let url = directory.appendingPathComponent(entry.fileName)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, scale: 2)
        thumbnails[entry.id] = image
        return image
    }

    func clear() {
        trim(to: 0)
        saveIndex()
        NotificationCenter.default.post(name: .historyChanged, object: nil)
    }

    private func trim(to limit: Int) {
        while entries.count > max(0, limit) {
            let removed = entries.removeLast()
            thumbnails[removed.id] = nil
            do {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(removed.fileName))
            } catch {
                Log.output.error("Could not delete history file: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        do {
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            Log.output.error("History index unreadable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveIndex() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: indexURL, options: .atomic)
        } catch {
            Log.output.error("History index write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
