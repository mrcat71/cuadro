import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation

public struct RenderOptions: Sendable {
    /// Annotation being edited inline (its text view draws it instead).
    public var hiddenAnnotationID: UUID?
    /// Ignore crop and backdrop; the crop tool shows the whole screenshot.
    public var showsFullImage: Bool

    public init(hiddenAnnotationID: UUID? = nil, showsFullImage: Bool = false) {
        self.hiddenAnnotationID = hiddenAnnotationID
        self.showsFullImage = showsFullImage
    }
}

/// Draws a screenshot with its markup. The editor canvas and export share this code path, so
/// what you see is what you get. Contexts are expected in y-down point space.
public final class DocumentRenderer {
    public let baseImage: CGImage
    /// Pixels per point of the base image (2 for Retina captures).
    public let scale: CGFloat
    /// Pasted images referenced by `.image` annotations.
    public var overlayImages: [UUID: CGImage] = [:]

    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])
    private var effects: [String: CGImage] = [:]

    public init(baseImage: CGImage, scale: CGFloat) {
        self.baseImage = baseImage
        self.scale = max(scale, 0.01)
    }

    /// Screenshot size in points.
    public var imageSize: CGSize {
        CGSize(width: CGFloat(baseImage.width) / scale, height: CGFloat(baseImage.height) / scale)
    }

    public var imageBounds: CGRect { CGRect(origin: .zero, size: imageSize) }

    public func layout(for state: DocumentState, options: RenderOptions = RenderOptions()) -> CanvasLayout {
        if options.showsFullImage {
            return CanvasLayout.make(imageSize: imageSize, scale: scale, crop: nil, backdrop: nil)
        }
        return CanvasLayout.make(imageSize: imageSize, scale: scale, crop: state.crop, backdrop: state.backdrop)
    }

    // MARK: Drawing

    /// Draws the document into `ctx` in canvas space (see `layout(for:options:)`).
    public func draw(_ state: DocumentState, in ctx: CGContext, options: RenderOptions = RenderOptions()) {
        let layout = layout(for: state, options: options)
        let backdrop = options.showsFullImage ? nil : state.backdrop
        let canvas = CGRect(origin: .zero, size: layout.canvasSize)

        ctx.saveGState()
        ctx.clip(to: canvas)
        if let backdrop {
            drawBackdropFill(backdrop.fill, in: canvas, ctx: ctx)
        }

        let shadow = backdrop?.shadow ?? 0
        ctx.saveGState()
        if shadow > 0 {
            setShadow(ctx, offsetY: 4 + 10 * shadow, blur: 8 + 30 * shadow, alpha: 0.2 + 0.3 * shadow)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        drawScreenshot(state, layout: layout, cornerRadius: backdrop?.cornerRadius ?? 0, ctx: ctx)
        if shadow > 0 {
            ctx.endTransparencyLayer()
        }
        ctx.restoreGState()

        // Markup may extend over the backdrop (Shottr's "expandable canvas").
        ctx.saveGState()
        ctx.concatenate(layout.documentToCanvas)
        for annotation in state.annotations
        where !annotation.kind.isObscuring && annotation.kind != .spotlight && annotation.id != options.hiddenAnnotationID {
            drawAnnotation(annotation, state: state, ctx: ctx)
        }
        ctx.restoreGState()
        ctx.restoreGState()
    }

    /// Renders the export image. `pixelsPerPoint` defaults to the capture scale.
    public func render(_ state: DocumentState, pixelsPerPoint: CGFloat? = nil) -> CGImage? {
        let layout = layout(for: state)
        let factor = (pixelsPerPoint ?? scale) * max(state.outputScale, 0.01)
        let width = max(1, Int((layout.canvasSize.width * factor).rounded()))
        let height = max(1, Int((layout.canvasSize.height * factor).rounded()))
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: exportColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(width) / layout.canvasSize.width, y: -CGFloat(height) / layout.canvasSize.height)
        draw(state, in: ctx)
        return ctx.makeImage()
    }

    /// The capture's own RGB color space when it can be rendered into, otherwise sRGB.
    public var exportColorSpace: CGColorSpace {
        if let space = baseImage.colorSpace, space.model == .rgb, space.supportsOutput {
            return space
        }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    // MARK: Layers

    private func drawScreenshot(_ state: DocumentState, layout: CanvasLayout, cornerRadius: CGFloat, ctx: CGContext) {
        ctx.saveGState()
        if cornerRadius > 0 {
            let radius = min(cornerRadius, layout.imageRect.width / 2, layout.imageRect.height / 2)
            ctx.addPath(CGPath(roundedRect: layout.imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
        } else {
            ctx.clip(to: layout.imageRect)
        }
        ctx.concatenate(layout.documentToCanvas)
        drawImage(baseImage, in: imageBounds, ctx: ctx)
        drawObscuring(state, ctx: ctx)
        drawSpotlights(state, ctx: ctx)
        ctx.restoreGState()
    }

    private func drawObscuring(_ state: DocumentState, ctx: CGContext) {
        for annotation in state.annotations where annotation.kind.isObscuring {
            let rect = annotation.rect
            switch annotation.kind {
            case .pixelate:
                if let image = pixelated(blockSize: annotation.style.pixelSize) {
                    ctx.saveGState()
                    ctx.clip(to: rect)
                    drawImage(image, in: imageBounds, ctx: ctx)
                    ctx.restoreGState()
                }
            case .blur:
                if let image = blurred(radius: annotation.style.blurRadius) {
                    ctx.saveGState()
                    ctx.clip(to: rect)
                    drawImage(image, in: imageBounds, ctx: ctx)
                    ctx.restoreGState()
                }
            case .erase:
                ctx.setFillColor((annotation.fillColor ?? .white).cgColor)
                ctx.fill(rect)
            default:
                break
            }
        }
    }

    private func drawSpotlights(_ state: DocumentState, ctx: CGContext) {
        let spots = state.annotations.filter { $0.kind == .spotlight }
        guard !spots.isEmpty, state.spotlightOpacity > 0 else { return }
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: CGFloat(state.spotlightOpacity)))
        ctx.fill(imageBounds)
        ctx.setBlendMode(.clear)
        for spot in spots {
            let rect = spot.rect
            if spot.style.spotlightShape == .ellipse {
                ctx.fillEllipse(in: rect)
            } else {
                let radius = min(spot.style.cornerRadius, rect.width / 2, rect.height / 2)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private func drawBackdropFill(_ fill: BackdropFill, in rect: CGRect, ctx: CGContext) {
        switch fill {
        case .transparent:
            break
        case .solid(let color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
        case .gradient(let preset):
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let gradient = CGGradient(colorsSpace: space, colors: preset.colors.map(\.cgColor) as CFArray, locations: nil)
            else { return }
            let angle = preset.angle * .pi / 180
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            let half = (abs(rect.width * direction.x) + abs(rect.height * direction.y)) / 2
            ctx.drawLinearGradient(
                gradient,
                start: rect.center - direction * half,
                end: rect.center + direction * half,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
    }

    // MARK: Annotations

    private func drawAnnotation(_ annotation: Annotation, state: DocumentState, ctx: CGContext) {
        let style = annotation.style
        let color = style.color.cgColor
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if style.shadow {
            setShadow(ctx, offsetY: 1.5, blur: 4, alpha: 0.35)
        }

        switch annotation.kind {
        case .arrow:
            drawArrow(annotation, ctx: ctx)

        case .line:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(style.lineWidth)
            ctx.setLineCap(.round)
            if style.dashed {
                ctx.setLineDash(phase: 0, lengths: [style.lineWidth * 2.5, style.lineWidth * 2])
            }
            ctx.move(to: annotation.start)
            ctx.addLine(to: annotation.end)
            ctx.strokePath()

        case .rectangle, .ellipse:
            let rect = annotation.rect
            let path: CGPath
            if annotation.kind == .ellipse {
                path = CGPath(ellipseIn: rect, transform: nil)
            } else {
                let radius = min(style.cornerRadius, rect.width / 2, rect.height / 2)
                path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
            if style.fill != .none {
                ctx.saveGState()
                if style.fill == .translucent {
                    ctx.setShadow(offset: .zero, blur: 0, color: nil)
                }
                ctx.addPath(path)
                ctx.setFillColor(style.fill == .solid ? color : style.color.withAlpha(0.25).cgColor)
                ctx.fillPath()
                ctx.restoreGState()
            }
            if style.fill != .solid || style.dashed {
                ctx.addPath(path)
                ctx.setStrokeColor(color)
                ctx.setLineWidth(style.lineWidth)
                ctx.setLineJoin(.round)
                if style.dashed {
                    ctx.setLineDash(phase: 0, lengths: [style.lineWidth * 2.5, style.lineWidth * 2])
                }
                ctx.strokePath()
            }

        case .pen:
            ctx.addPath(Self.smoothPath(annotation.points))
            ctx.setStrokeColor(color)
            ctx.setLineWidth(style.lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()

        case .highlighter:
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setBlendMode(.multiply)
            let rect = annotation.rect
            let radius = min(style.cornerRadius, rect.width / 2, rect.height / 2)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(style.color.withAlpha(0.45).cgColor)
            ctx.fillPath()

        case .text:
            TextLayout.draw(annotation.text, style: style, at: annotation.start, in: ctx)

        case .counter:
            drawCounter(annotation, ctx: ctx)

        case .magnifier:
            drawMagnifier(annotation, state: state, ctx: ctx)

        case .measure:
            drawMeasure(annotation, ctx: ctx)

        case .image:
            if let id = annotation.imageID, let image = overlayImages[id] {
                drawImage(image, in: annotation.rect, ctx: ctx)
            }

        case .pixelate, .blur, .erase, .spotlight:
            break
        }
    }

    private func drawArrow(_ annotation: Annotation, ctx: CGContext) {
        let style = annotation.style
        let doubleHeaded = style.arrowHeads == .both
        ctx.setFillColor(style.color.cgColor)
        ctx.setStrokeColor(style.color.cgColor)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if let bend = annotation.bend {
            let parts = ArrowGeometry.curvedArrow(
                from: annotation.start, to: annotation.end, through: bend,
                lineWidth: style.lineWidth, doubleHeaded: doubleHeaded
            )
            ctx.addPath(parts.shaft)
            ctx.setLineWidth(style.lineWidth)
            ctx.strokePath()
            ctx.addPath(parts.heads)
            ctx.fillPath()
            ctx.addPath(parts.heads)
            ctx.setLineWidth(max(1, style.lineWidth * 0.3))
            ctx.strokePath()
        } else {
            let path = ArrowGeometry.straightArrowPath(
                from: annotation.start, to: annotation.end,
                lineWidth: style.lineWidth, doubleHeaded: doubleHeaded
            )
            ctx.addPath(path)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setLineWidth(max(1, style.lineWidth * 0.3))
            ctx.strokePath()
        }
        ctx.endTransparencyLayer()
    }

    private func drawCounter(_ annotation: Annotation, ctx: CGContext) {
        let style = annotation.style
        let radius = Annotation.counterRadius(fontSize: style.fontSize)
        let circle = CGRect(x: annotation.start.x - radius, y: annotation.start.y - radius, width: radius * 2, height: radius * 2)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(style.color.cgColor)
        // The pointer starts at the badge's center, so the badge drawn on top hides its tail.
        if annotation.hasCounterPointer, annotation.start.distance(to: annotation.end) > radius {
            let width = Annotation.counterPointerWidth(radius: radius)
            let pointer = ArrowGeometry.straightArrowPath(from: annotation.start, to: annotation.end, lineWidth: width, doubleHeaded: false)
            ctx.setStrokeColor(style.color.cgColor)
            ctx.setLineJoin(.round)
            ctx.addPath(pointer)
            ctx.fillPath()
            ctx.addPath(pointer)
            ctx.setLineWidth(max(1, width * 0.3))
            ctx.strokePath()
        }
        ctx.fillEllipse(in: circle)
        let ring = max(1.5, radius * 0.12)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setLineWidth(ring)
        ctx.strokeEllipse(in: circle.insetBy(dx: ring / 2, dy: ring / 2))
        TextLayout.drawCentered(
            "\(annotation.number)",
            font: TextLayout.font(size: radius * 1.05, weight: 0.5),
            color: style.color.contrastingTextColor,
            center: annotation.start,
            in: ctx
        )
        ctx.endTransparencyLayer()
    }

    private func drawMagnifier(_ annotation: Annotation, state: DocumentState, ctx: CGContext) {
        let rect = annotation.rect
        guard rect.width > 2, rect.height > 2 else { return }
        let style = annotation.style
        // The filled disc casts the shadow; nothing after it should.
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: rect)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        let center = rect.center
        let zoom = max(1, style.magnification)
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: zoom, y: zoom)
        ctx.translateBy(x: -center.x, y: -center.y)
        ctx.interpolationQuality = .none
        drawImage(baseImage, in: imageBounds, ctx: ctx)
        // Keep redactions redacted inside the loupe.
        drawObscuring(state, ctx: ctx)
        ctx.restoreGState()

        ctx.setStrokeColor(style.color.cgColor)
        ctx.setLineWidth(style.lineWidth)
        ctx.strokeEllipse(in: rect)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.25))
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: rect.insetBy(dx: -style.lineWidth / 2, dy: -style.lineWidth / 2))
    }

    /// Label for a measured distance in points (shown as px for 1x images).
    public func measurementLabel(points: CGFloat) -> String {
        let unit = scale == 1 ? "px" : "pt"
        return "\(Int(points.rounded())) \(unit)"
    }

    private func drawMeasure(_ annotation: Annotation, ctx: CGContext) {
        let style = annotation.style
        let start = annotation.start
        let end = annotation.end
        let length = start.distance(to: end)
        guard length > 0 else { return }
        let u = (end - start).normalized
        let n = CGPoint(x: -u.y, y: u.x)
        let tick = max(6, style.lineWidth * 3)

        ctx.setStrokeColor(style.color.cgColor)
        ctx.setLineWidth(style.lineWidth)
        ctx.setLineCap(.butt)
        ctx.move(to: start)
        ctx.addLine(to: end)
        ctx.move(to: start + n * tick)
        ctx.addLine(to: start - n * tick)
        ctx.move(to: end + n * tick)
        ctx.addLine(to: end - n * tick)
        ctx.strokePath()

        let label = measurementLabel(points: length)
        let font = TextLayout.font(size: style.fontSize, weight: 0.4)
        let size = TextLayout.lineSize(label, font: font)
        let mid = start.midpoint(end)
        let pill = CGRect(
            x: mid.x - size.width / 2 - style.fontSize * 0.45, y: mid.y - size.height / 2 - style.fontSize * 0.25,
            width: size.width + style.fontSize * 0.9, height: size.height + style.fontSize * 0.5
        )
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        ctx.setFillColor(style.color.cgColor)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        TextLayout.drawCentered(label, font: font, color: style.color.contrastingTextColor, center: mid, in: ctx)
    }

    // MARK: Effects

    func pixelated(blockSize: CGFloat) -> CGImage? {
        let pixels = max(2, (blockSize * scale).rounded())
        return effect(key: "pixelate-\(Int(pixels))") { input in
            let filter = CIFilter.pixellate()
            filter.inputImage = input
            filter.scale = Float(pixels)
            filter.center = .zero
            return filter.outputImage
        }
    }

    func blurred(radius: CGFloat) -> CGImage? {
        let pixels = max(1, (radius * scale).rounded())
        return effect(key: "blur-\(Int(pixels))") { input in
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = input
            filter.radius = Float(pixels)
            return filter.outputImage
        }
    }

    private func effect(key: String, filter: (CIImage) -> CIImage?) -> CGImage? {
        if let cached = effects[key] { return cached }
        let source = CIImage(cgImage: baseImage)
        guard let output = filter(source.clampedToExtent())?.cropped(to: source.extent),
              let image = ciContext.createCGImage(output, from: source.extent, format: .RGBA8, colorSpace: exportColorSpace)
        else { return nil }
        effects[key] = image
        return image
    }

    // MARK: Helpers

    /// Draws a CGImage into `rect` of a y-down context.
    public func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// Sets a drop shadow given in user-space points (positive `offsetY` points down on screen).
    private func setShadow(_ ctx: CGContext, offsetY: CGFloat, blur: CGFloat, alpha: CGFloat) {
        let t = ctx.userSpaceToDeviceSpaceTransform
        let deviceScale = abs(t.a * t.d - t.b * t.c).squareRoot()
        ctx.setShadow(
            offset: CGSize(width: t.c * offsetY, height: t.d * offsetY),
            blur: blur * deviceScale,
            color: CGColor(gray: 0, alpha: alpha)
        )
    }

    /// Smooth freehand path through `points` using midpoint quadratic segments.
    public static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            for point in points.dropFirst() { path.addLine(to: point) }
            return path
        }
        for index in 1..<(points.count - 1) {
            path.addQuadCurve(to: points[index].midpoint(points[index + 1]), control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
