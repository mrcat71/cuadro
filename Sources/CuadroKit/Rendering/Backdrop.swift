import CoreGraphics
import Foundation

public struct GradientPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var colors: [RGBAColor]
    /// Direction in degrees in y-down space: 0 points right, 90 points down.
    public var angle: Double

    public init(id: String, name: String, colors: [RGBAColor], angle: Double = 45) {
        self.id = id
        self.name = name
        self.colors = colors
        self.angle = angle
    }
}

public enum BackdropFill: Codable, Hashable, Sendable {
    case gradient(GradientPreset)
    case solid(RGBAColor)
    case transparent
}

public enum BackdropAspect: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, square, fourThree, threeTwo, sixteenTen, sixteenNine

    public var id: String { rawValue }

    public var ratio: CGFloat? {
        switch self {
        case .auto: nil
        case .square: 1
        case .fourThree: 4.0 / 3.0
        case .threeTwo: 3.0 / 2.0
        case .sixteenTen: 16.0 / 10.0
        case .sixteenNine: 16.0 / 9.0
        }
    }

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .square: "1:1"
        case .fourThree: "4:3"
        case .threeTwo: "3:2"
        case .sixteenTen: "16:10"
        case .sixteenNine: "16:9"
        }
    }
}

/// Background, padding, rounded corners and shadow around the screenshot.
public struct Backdrop: Codable, Hashable, Sendable {
    public var fill: BackdropFill
    public var padding: CGFloat
    public var cornerRadius: CGFloat
    /// Shadow strength, 0...1.
    public var shadow: Double
    public var aspect: BackdropAspect

    public init(
        fill: BackdropFill = .gradient(Backdrop.presets[0]),
        padding: CGFloat = 56,
        cornerRadius: CGFloat = 12,
        shadow: Double = 0.6,
        aspect: BackdropAspect = .auto
    ) {
        self.fill = fill
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.aspect = aspect
    }

    public static let presets: [GradientPreset] = [
        GradientPreset(id: "dusk", name: "Dusk", colors: [RGBAColor(hex: "#4F7CFF")!, RGBAColor(hex: "#7C4DFF")!, RGBAColor(hex: "#E85DBA")!]),
        GradientPreset(id: "ocean", name: "Ocean", colors: [RGBAColor(hex: "#2BC0E4")!, RGBAColor(hex: "#1E6FD9")!]),
        GradientPreset(id: "aurora", name: "Aurora", colors: [RGBAColor(hex: "#00C9FF")!, RGBAColor(hex: "#92FE9D")!]),
        GradientPreset(id: "mint", name: "Mint", colors: [RGBAColor(hex: "#43E97B")!, RGBAColor(hex: "#38F9D7")!]),
        GradientPreset(id: "sunset", name: "Sunset", colors: [RGBAColor(hex: "#F7971E")!, RGBAColor(hex: "#FFD200")!]),
        GradientPreset(id: "peach", name: "Peach", colors: [RGBAColor(hex: "#FFB88C")!, RGBAColor(hex: "#DE6262")!]),
        GradientPreset(id: "rose", name: "Rose", colors: [RGBAColor(hex: "#F857A6")!, RGBAColor(hex: "#FF5858")!]),
        GradientPreset(id: "grape", name: "Grape", colors: [RGBAColor(hex: "#A18CD1")!, RGBAColor(hex: "#FBC2EB")!]),
        GradientPreset(id: "sky", name: "Sky", colors: [RGBAColor(hex: "#89F7FE")!, RGBAColor(hex: "#66A6FF")!]),
        GradientPreset(id: "paper", name: "Paper", colors: [RGBAColor(hex: "#F5F7FA")!, RGBAColor(hex: "#C3CFE2")!]),
        GradientPreset(id: "night", name: "Night", colors: [RGBAColor(hex: "#0F2027")!, RGBAColor(hex: "#203A43")!, RGBAColor(hex: "#2C5364")!]),
        GradientPreset(id: "graphite", name: "Graphite", colors: [RGBAColor(hex: "#434343")!, RGBAColor(hex: "#000000")!]),
    ]
}

/// Where the (cropped) screenshot sits on the output canvas.
public struct CanvasLayout: Equatable, Sendable {
    /// Output canvas size in points.
    public var canvasSize: CGSize
    /// Screenshot area inside the canvas.
    public var imageRect: CGRect
    /// Visible part of the document (crop) in document points.
    public var cropRect: CGRect

    public init(canvasSize: CGSize, imageRect: CGRect, cropRect: CGRect) {
        self.canvasSize = canvasSize
        self.imageRect = imageRect
        self.cropRect = cropRect
    }

    public var offset: CGPoint {
        CGPoint(x: imageRect.minX - cropRect.minX, y: imageRect.minY - cropRect.minY)
    }

    public var documentToCanvas: CGAffineTransform {
        CGAffineTransform(translationX: offset.x, y: offset.y)
    }

    public func canvasPoint(fromDocument point: CGPoint) -> CGPoint { point + offset }

    public func documentPoint(fromCanvas point: CGPoint) -> CGPoint { point - offset }

    public func canvasRect(fromDocument rect: CGRect) -> CGRect { rect.offsetBy(dx: offset.x, dy: offset.y) }

    /// Layout for a screenshot of `imageSize` points at `scale` pixels per point.
    public static func make(imageSize: CGSize, scale: CGFloat, crop: CGRect?, backdrop: Backdrop?) -> CanvasLayout {
        let full = CGRect(origin: .zero, size: imageSize)
        var visible = (crop ?? full).intersection(full)
        if visible.isNull || visible.width < 1 / max(scale, 1) || visible.height < 1 / max(scale, 1) {
            visible = full
        }
        guard let backdrop else {
            return CanvasLayout(canvasSize: visible.size, imageRect: CGRect(origin: .zero, size: visible.size), cropRect: visible)
        }
        let pixel = max(scale, 1)
        var width = visible.width + backdrop.padding * 2
        var height = visible.height + backdrop.padding * 2
        if let ratio = backdrop.aspect.ratio {
            if width / height < ratio { width = height * ratio } else { height = width / ratio }
        }
        width = (width * pixel).rounded(.up) / pixel
        height = (height * pixel).rounded(.up) / pixel
        let x = ((width - visible.width) / 2 * pixel).rounded() / pixel
        let y = ((height - visible.height) / 2 * pixel).rounded() / pixel
        return CanvasLayout(
            canvasSize: CGSize(width: width, height: height),
            imageRect: CGRect(x: x, y: y, width: visible.width, height: visible.height),
            cropRect: visible
        )
    }
}
