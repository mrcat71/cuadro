import AppKit
import CuadroKit
import ImageIO
import UniformTypeIdentifiers

/// Encodes images and applies the output settings (1x downscale, JPEG flattening).
/// The `nonisolated` functions are pure and safe to call off the main actor.
enum ImageExporter {
    /// The image as it should be shared: downscaled to 1x when the setting asks for it.
    static func prepared(_ image: CGImage, scale: CGFloat) -> (image: CGImage, scale: CGFloat) {
        prepare(image, scale: scale, downscale: AppSettings.shared.downscaleRetina)
    }

    nonisolated static func prepare(_ image: CGImage, scale: CGFloat, downscale: Bool) -> (image: CGImage, scale: CGFloat) {
        guard downscale, scale > 1 else { return (image, scale) }
        let width = max(1, Int((CGFloat(image.width) / scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) / scale).rounded()))
        guard let resized = resize(image, width: width, height: height) else { return (image, scale) }
        return (resized, 1)
    }

    nonisolated static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: outputSpace(for: image), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Fills transparent areas with white, for formats without alpha.
    nonisolated static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: outputSpace(for: image), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// Encoded file data; DPI metadata makes Retina images open at their point size.
    /// - Parameter quality: lossy compression quality, ignored for PNG.
    nonisolated static func encode(_ image: CGImage, typeIdentifier: String, scale: CGFloat, quality: Double? = nil, flatten: Bool = false) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, typeIdentifier as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, flatten ? flattened(image) : image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    nonisolated static func encodePNG(_ image: CGImage, scale: CGFloat) -> Data? {
        encode(image, typeIdentifier: UTType.png.identifier, scale: scale)
    }

    static func data(for image: CGImage, format: ImageFormat, scale: CGFloat, quality: Double = AppSettings.shared.jpegQuality) -> Data? {
        encode(
            image, typeIdentifier: format.type.identifier, scale: scale,
            quality: format == .png ? nil : quality, flatten: format == .jpeg
        )
    }

    /// Per-process scratch folder for drag and drop, sharing and Preview.
    static let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Cuadro", isDirectory: true)

    /// Writes a PNG of `image` to a temporary file, for drag and drop and sharing.
    static func temporaryFile(for image: CGImage, scale: CGFloat, name: String = "Screenshot") throws -> URL {
        let directory = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prepared = prepared(image, scale: scale)
        guard let data = encodePNG(prepared.image, scale: prepared.scale) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = directory.appendingPathComponent(FileNameTemplate.sanitize(name)).appendingPathExtension("png")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Removes files left over from earlier runs (receivers have long finished reading them).
    static func removeStaleTemporaryFiles() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: temporaryDirectory.path) else { return }
        do {
            try manager.removeItem(at: temporaryDirectory)
        } catch {
            Log.output.error("Could not clean temporary files: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func outputSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.supportsOutput { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }
}
