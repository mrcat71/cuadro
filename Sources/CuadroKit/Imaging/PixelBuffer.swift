import CoreGraphics
import Foundation

/// Integer pixel rectangle with a top-left origin.
public struct PixelRect: Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Smallest pixel rectangle covering `rect` (in pixels).
    public init(covering rect: CGRect) {
        let minX = Int(rect.minX.rounded(.down))
        let minY = Int(rect.minY.rounded(.down))
        let maxX = Int(rect.maxX.rounded(.up))
        let maxY = Int(rect.maxY.rounded(.up))
        self.init(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public func clamped(width boundsWidth: Int, height boundsHeight: Int) -> PixelRect {
        let minX = max(0, x), minY = max(0, y)
        let maxX = min(boundsWidth, self.maxX), maxY = min(boundsHeight, self.maxY)
        return PixelRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}

/// RGBA8 pixels in sRGB with premultiplied alpha, rows top to bottom.
public struct PixelBuffer: Sendable {
    public let width: Int
    public let height: Int
    public private(set) var bytes: [UInt8]

    public var bytesPerRow: Int { width * 4 }

    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4, "PixelBuffer byte count mismatch")
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public init(width: Int, height: Int, fill: RGBAColor) {
        self.width = width
        self.height = height
        let pixel = Self.premultiplied(fill)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: data.count, by: 4) {
            data[index] = pixel.0
            data[index + 1] = pixel.1
            data[index + 2] = pixel.2
            data[index + 3] = pixel.3
        }
        bytes = data
    }

    /// Renders `image` (or a pixel region of it) into an sRGB RGBA8 buffer.
    public init?(image: CGImage, region: PixelRect? = nil) {
        let bounds = PixelRect(x: 0, y: 0, width: image.width, height: image.height)
        let area = (region ?? bounds).clamped(width: image.width, height: image.height)
        guard !area.isEmpty else { return nil }
        let source = area == bounds ? image : image.cropping(to: area.cgRect)
        guard let source, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var data = [UInt8](repeating: 0, count: area.width * area.height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: area.width, height: area.height, bitsPerComponent: 8,
                bytesPerRow: area.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(source, in: CGRect(x: 0, y: 0, width: area.width, height: area.height))
            return true
        }
        guard drawn else { return nil }
        width = area.width
        height = area.height
        bytes = data
    }

    public func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    /// Raw premultiplied RGBA bytes at a pixel.
    @inline(__always)
    public func rgba(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let index = (y * width + x) * 4
        return (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3])
    }

    /// Un-premultiplied color at a pixel.
    public func color(x: Int, y: Int) -> RGBAColor {
        let (r, g, b, a) = rgba(x: x, y: y)
        guard a > 0 else { return .clear }
        guard a < 255 else { return RGBAColor(red8: r, green8: g, blue8: b) }
        let alpha = Double(a) / 255
        return RGBAColor(
            red: min(1, Double(r) / 255 / alpha), green: min(1, Double(g) / 255 / alpha),
            blue: min(1, Double(b) / 255 / alpha), alpha: alpha
        )
    }

    public mutating func setColor(_ color: RGBAColor, x: Int, y: Int) {
        let index = (y * width + x) * 4
        let pixel = Self.premultiplied(color)
        bytes[index] = pixel.0
        bytes[index + 1] = pixel.1
        bytes[index + 2] = pixel.2
        bytes[index + 3] = pixel.3
    }

    public mutating func fill(_ rect: PixelRect, with color: RGBAColor) {
        let area = rect.clamped(width: width, height: height)
        guard !area.isEmpty else { return }
        for y in area.y..<area.maxY {
            for x in area.x..<area.maxX {
                setColor(color, x: x, y: y)
            }
        }
    }

    public func makeImage() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    static func premultiplied(_ color: RGBAColor) -> (UInt8, UInt8, UInt8, UInt8) {
        let alpha = max(0, min(1, color.alpha))
        return (
            RGBAColor.byte(color.red * alpha), RGBAColor.byte(color.green * alpha),
            RGBAColor.byte(color.blue * alpha), RGBAColor.byte(alpha)
        )
    }
}
