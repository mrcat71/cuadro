import CoreGraphics
import Foundation

public enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case arrow, line, rectangle, ellipse, pen, highlighter, text, counter
    case pixelate, blur, erase, spotlight, magnifier, measure, image

    /// Obscuring kinds are painted right on top of the screenshot, under everything else.
    public var isObscuring: Bool {
        switch self {
        case .pixelate, .blur, .erase: true
        default: false
        }
    }

    /// Kinds whose geometry is the rectangle spanned by `start` and `end`.
    public var isBoxed: Bool {
        switch self {
        case .rectangle, .ellipse, .highlighter, .pixelate, .blur, .erase, .spotlight, .magnifier, .image: true
        default: false
        }
    }

    /// Kinds whose geometry is the segment from `start` to `end`.
    public var isSegment: Bool {
        switch self {
        case .arrow, .line, .measure: true
        default: false
        }
    }
}

public enum FillMode: String, Codable, CaseIterable, Sendable {
    case none, translucent, solid
}

public enum ArrowHeads: String, Codable, CaseIterable, Sendable {
    case end, both
}

public enum TextStyle: String, Codable, CaseIterable, Sendable {
    case plain, outline, pill
}

public enum SpotlightShape: String, Codable, CaseIterable, Sendable {
    case rectangle, ellipse
}

public struct AnnotationStyle: Codable, Equatable, Sendable {
    public var color: RGBAColor
    public var lineWidth: CGFloat
    public var fill: FillMode
    public var cornerRadius: CGFloat
    public var arrowHeads: ArrowHeads
    public var dashed: Bool
    public var shadow: Bool
    public var fontSize: CGFloat
    public var textStyle: TextStyle
    public var pixelSize: CGFloat
    public var blurRadius: CGFloat
    public var magnification: CGFloat
    public var spotlightShape: SpotlightShape

    public init(
        color: RGBAColor = RGBAColor.palette[0],
        lineWidth: CGFloat = 4,
        fill: FillMode = .none,
        cornerRadius: CGFloat = 6,
        arrowHeads: ArrowHeads = .end,
        dashed: Bool = false,
        shadow: Bool = true,
        fontSize: CGFloat = 20,
        textStyle: TextStyle = .pill,
        pixelSize: CGFloat = 10,
        blurRadius: CGFloat = 10,
        magnification: CGFloat = 2,
        spotlightShape: SpotlightShape = .rectangle
    ) {
        self.color = color
        self.lineWidth = lineWidth
        self.fill = fill
        self.cornerRadius = cornerRadius
        self.arrowHeads = arrowHeads
        self.dashed = dashed
        self.shadow = shadow
        self.fontSize = fontSize
        self.textStyle = textStyle
        self.pixelSize = pixelSize
        self.blurRadius = blurRadius
        self.magnification = magnification
        self.spotlightShape = spotlightShape
    }

    /// Starting style for each kind of annotation.
    public static func defaults(for kind: AnnotationKind) -> AnnotationStyle {
        var style = AnnotationStyle()
        switch kind {
        case .highlighter:
            style.color = RGBAColor.palette[2]
            style.shadow = false
            style.cornerRadius = 3
        case .text:
            style.textStyle = .pill
        case .counter:
            style.fontSize = 18
        case .measure:
            style.color = RGBAColor(hex: "#FF2D55")!
            style.lineWidth = 2
            style.fontSize = 13
        case .magnifier:
            style.color = .white
            style.lineWidth = 4
        case .pen:
            style.lineWidth = 4
        case .pixelate, .blur, .erase, .spotlight:
            style.shadow = false
        default:
            break
        }
        return style
    }
}

/// One markup object on a screenshot. Coordinates are document points (y down, origin at the
/// top-left of the uncropped screenshot).
public struct Annotation: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: AnnotationKind
    public var start: CGPoint
    public var end: CGPoint
    /// Arrow only: a point the curve passes through at its middle; `nil` means straight.
    public var bend: CGPoint?
    /// Pen strokes.
    public var points: [CGPoint]
    public var style: AnnotationStyle
    public var text: String
    /// Step counter value.
    public var number: Int
    /// Smart eraser fill sampled from the surrounding pixels.
    public var fillColor: RGBAColor?
    /// Pasted image overlays reference images stored next to the document.
    public var imageID: UUID?

    public init(
        id: UUID = UUID(),
        kind: AnnotationKind,
        start: CGPoint,
        end: CGPoint? = nil,
        style: AnnotationStyle? = nil
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end ?? start
        self.bend = nil
        self.points = []
        self.style = style ?? .defaults(for: kind)
        self.text = ""
        self.number = 0
        self.fillColor = nil
        self.imageID = nil
    }

    /// Normalized rectangle between `start` and `end`.
    public var rect: CGRect { CGRect(corners: start, end) }
}

/// Everything the user can change about a screenshot, as a value for cheap undo snapshots.
public struct DocumentState: Codable, Equatable, Sendable {
    public var annotations: [Annotation]
    /// Visible part of the screenshot in document points; `nil` shows everything.
    public var crop: CGRect?
    public var backdrop: Backdrop?
    /// Darkness outside spotlights, 0...1.
    public var spotlightOpacity: Double
    /// Export size multiplier (Resize).
    public var outputScale: CGFloat

    public init(
        annotations: [Annotation] = [],
        crop: CGRect? = nil,
        backdrop: Backdrop? = nil,
        spotlightOpacity: Double = 0.6,
        outputScale: CGFloat = 1
    ) {
        self.annotations = annotations
        self.crop = crop
        self.backdrop = backdrop
        self.spotlightOpacity = spotlightOpacity
        self.outputScale = outputScale
    }

    public func annotation(withID id: UUID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    /// Next step-counter number.
    public var nextCounterNumber: Int {
        (annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1
    }
}
