import AppKit
import CuadroKit
import QuartzCore
import SwiftUI

/// Everything the overlay draws for one display, computed by `OverlayController`.
struct OverlayRenderState {
    var mode: OverlayMode = .area
    var isActive = false
    var pointer: CGPoint?
    var selection: CGRect?
    var highlight: CGRect?
    var showsCrosshair = false
    var dimsScreen = true
    var rulerLines: [(CGPoint, CGPoint)] = []
    var rulerBox: CGRect?
    var label: String?
    var labelAnchor: CGRect?
    var loupe: LoupeState?
    var hint: String = ""
}

struct LoupeState {
    var pixelX: Int
    var pixelY: Int
    var pointLabel: String
    var color: RGBAColor?
    var colorText: String
    var contrast: String?
    var large: Bool
}

/// Content view of an overlay window: frozen screenshot, dimming and selection chrome.
final class OverlayView: NSView {
    let snapshot: DisplaySnapshot
    weak var controller: OverlayController?

    private let imageView = NSImageView()
    private let shapes = OverlayShapesView()
    private let loupe = LoupeView()
    private let infoHost = NSHostingView(rootView: InfoPill(lines: []))
    private let labelHost = NSHostingView(rootView: GlassLabel(text: ""))
    private let hintHost = NSHostingView(rootView: GlassLabel(text: ""))
    private var trackingArea: NSTrackingArea?

    init(snapshot: DisplaySnapshot, controller: OverlayController) {
        self.snapshot = snapshot
        self.controller = controller
        super.init(frame: CGRect(origin: .zero, size: snapshot.frame.size))
        wantsLayer = true

        imageView.image = NSImage(cgImage: snapshot.image, scale: snapshot.scale)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        shapes.frame = bounds
        shapes.autoresizingMask = [.width, .height]
        addSubview(shapes)

        for host in [labelHost, hintHost] as [NSView] {
            host.isHidden = true
            addSubview(host)
        }
        loupe.isHidden = true
        addSubview(loupe)
        infoHost.isHidden = true
        addSubview(infoHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// All events go to the overlay itself, never to the decorative subviews.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        controller?.pointerMoved(in: self, to: point(of: event))
    }

    override func mouseDown(with event: NSEvent) {
        controller?.pointerDown(in: self, at: point(of: event), event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.pointerDragged(in: self, to: point(of: event), event: event)
    }

    override func mouseUp(with event: NSEvent) {
        controller?.pointerUp(in: self, at: point(of: event), event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.cancel()
    }

    override func keyDown(with event: NSEvent) {
        if controller?.keyDown(event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        controller?.keyUp(event)
    }

    override func flagsChanged(with event: NSEvent) {
        controller?.flagsChanged(event)
    }

    override func scrollWheel(with event: NSEvent) {
        controller?.scrollWheel(event)
    }

    // MARK: Coordinates

    private func point(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    func globalPoint(fromLocal point: CGPoint) -> CGPoint {
        CGPoint(x: snapshot.frame.minX + point.x, y: snapshot.frame.maxY - point.y)
    }

    func localPoint(fromGlobal point: CGPoint) -> CGPoint {
        ScreenCoordinates.localTopLeft(fromCocoa: point, screenFrame: snapshot.frame)
    }

    func localRect(fromGlobal rect: CGRect) -> CGRect {
        ScreenCoordinates.localTopLeft(fromCocoa: rect, screenFrame: snapshot.frame)
    }

    // MARK: Rendering

    func render(_ state: OverlayRenderState) {
        shapes.render(state)

        if let text = state.label, let anchor = state.labelAnchor {
            labelHost.rootView = GlassLabel(text: text)
            let size = labelHost.fittingSize
            var origin = CGPoint(x: anchor.maxX - size.width + 8, y: anchor.maxY + 2)
            if origin.y + size.height > bounds.maxY { origin.y = anchor.minY - size.height - 2 }
            if origin.y < bounds.minY { origin.y = anchor.minY + 4 }
            origin.x = min(max(origin.x, bounds.minX - 6), bounds.maxX - size.width + 6)
            labelHost.frame = CGRect(origin: origin, size: size)
            labelHost.isHidden = false
        } else {
            labelHost.isHidden = true
        }

        if state.isActive, !state.hint.isEmpty {
            hintHost.rootView = GlassLabel(text: state.hint, secondary: true)
            let size = hintHost.fittingSize
            hintHost.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 18, width: size.width, height: size.height)
            hintHost.isHidden = false
        } else {
            hintHost.isHidden = true
        }

        if let loupeState = state.loupe, let pointer = state.pointer, state.isActive {
            loupe.update(image: snapshot.image, state: loupeState)
            let size = loupe.preferredSize(large: loupeState.large)
            var lines = [loupeState.pointLabel, loupeState.colorText]
            if let contrast = loupeState.contrast { lines.append(contrast) }
            infoHost.rootView = InfoPill(lines: lines, swatch: loupeState.color)
            let infoSize = infoHost.fittingSize
            let total = CGSize(width: max(size.width, infoSize.width), height: size.height + infoSize.height - 6)
            var origin = CGPoint(x: pointer.x + 26, y: pointer.y + 26)
            if origin.x + total.width > bounds.maxX { origin.x = pointer.x - 26 - total.width }
            if origin.y + total.height > bounds.maxY { origin.y = pointer.y - 26 - total.height }
            loupe.frame = CGRect(x: origin.x + (total.width - size.width) / 2, y: origin.y, width: size.width, height: size.height)
            infoHost.frame = CGRect(x: origin.x + (total.width - infoSize.width) / 2, y: origin.y + size.height - 6, width: infoSize.width, height: infoSize.height)
            loupe.isHidden = false
            infoHost.isHidden = false
        } else {
            loupe.isHidden = true
            infoHost.isHidden = true
        }
    }
}

/// Layer-hosting view with GPU-composited shapes (dim mask, selection, crosshair, ruler).
final class OverlayShapesView: NSView {
    private let root = CALayer()
    private let dim = CAShapeLayer()
    private let selectionOutline = CAShapeLayer()
    private let selectionBorder = CAShapeLayer()
    private let highlight = CAShapeLayer()
    private let crosshair = CAShapeLayer()
    private let rulerOutline = CAShapeLayer()
    private let ruler = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = root
        wantsLayer = true
        let noAnimations: [String: CAAction] = [
            "path": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(),
            "opacity": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(),
        ]
        for shape in [dim, highlight, crosshair, selectionOutline, selectionBorder, rulerOutline, ruler] {
            shape.actions = noAnimations
            shape.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            root.addSublayer(shape)
        }
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.4).cgColor

        highlight.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        highlight.strokeColor = NSColor.controlAccentColor.cgColor
        highlight.lineWidth = 3

        crosshair.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        crosshair.lineWidth = 1
        crosshair.lineDashPattern = [4, 4]
        crosshair.fillColor = nil

        selectionOutline.strokeColor = NSColor.black.withAlphaComponent(0.35).cgColor
        selectionOutline.lineWidth = 3
        selectionOutline.fillColor = nil
        selectionBorder.strokeColor = NSColor.white.cgColor
        selectionBorder.lineWidth = 1
        selectionBorder.fillColor = nil

        rulerOutline.strokeColor = NSColor.black.withAlphaComponent(0.45).cgColor
        rulerOutline.lineWidth = 3
        rulerOutline.fillColor = nil
        ruler.strokeColor = NSColor.systemPink.cgColor
        ruler.lineWidth = 1
        ruler.fillColor = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        for shape in root.sublayers ?? [] { shape.frame = bounds }
    }

    /// Paths are built in the view's y-down space and flipped into the layer's y-up space.
    func render(_ state: OverlayRenderState) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
        for shape in root.sublayers ?? [] where shape.frame != bounds { shape.frame = bounds }

        let dimPath = CGMutablePath()
        if state.dimsScreen {
            dimPath.addRect(bounds, transform: flip)
            if let selection = state.selection {
                dimPath.addRect(selection, transform: flip)
            } else if let highlight = state.highlight {
                dimPath.addRoundedRect(in: highlight, cornerWidth: 10, cornerHeight: 10, transform: flip)
            }
        }
        dim.path = dimPath
        dim.fillColor = NSColor.black.withAlphaComponent(state.selection != nil || state.highlight != nil ? 0.45 : 0.2).cgColor

        if let selection = state.selection, selection.width > 0, selection.height > 0 {
            let path = CGPath(rect: selection.insetBy(dx: -0.5, dy: -0.5), transform: &flip)
            selectionOutline.path = path
            selectionBorder.path = path
        } else {
            selectionOutline.path = nil
            selectionBorder.path = nil
        }

        if let rect = state.highlight {
            highlight.path = CGPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 10, cornerHeight: 10, transform: &flip)
        } else {
            highlight.path = nil
        }

        if state.showsCrosshair, let pointer = state.pointer {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: bounds.minX, y: pointer.y), transform: flip)
            path.addLine(to: CGPoint(x: bounds.maxX, y: pointer.y), transform: flip)
            path.move(to: CGPoint(x: pointer.x, y: bounds.minY), transform: flip)
            path.addLine(to: CGPoint(x: pointer.x, y: bounds.maxY), transform: flip)
            crosshair.path = path
        } else {
            crosshair.path = nil
        }

        let rulerPath = CGMutablePath()
        for (start, end) in state.rulerLines {
            rulerPath.move(to: start, transform: flip)
            rulerPath.addLine(to: end, transform: flip)
            // End ticks.
            let horizontal = abs(end.y - start.y) < abs(end.x - start.x)
            for point in [start, end] {
                if horizontal {
                    rulerPath.move(to: CGPoint(x: point.x, y: point.y - 5), transform: flip)
                    rulerPath.addLine(to: CGPoint(x: point.x, y: point.y + 5), transform: flip)
                } else {
                    rulerPath.move(to: CGPoint(x: point.x - 5, y: point.y), transform: flip)
                    rulerPath.addLine(to: CGPoint(x: point.x + 5, y: point.y), transform: flip)
                }
            }
        }
        if let box = state.rulerBox {
            rulerPath.addRect(box, transform: flip)
        }
        ruler.path = rulerPath
        rulerOutline.path = rulerPath
    }
}

/// Magnified pixels around the pointer with a pixel grid.
final class LoupeView: NSView {
    private var pixels: CGImage?
    private var cells = 17

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func preferredSize(large: Bool) -> CGSize {
        let side: CGFloat = large ? 176 : 136
        return CGSize(width: side, height: side)
    }

    func update(image: CGImage, state: LoupeState) {
        cells = state.large ? 21 : 17
        let half = cells / 2
        let region = PixelRect(x: state.pixelX - half, y: state.pixelY - half, width: cells, height: cells)
        pixels = Self.sample(image, region: region)
        needsDisplay = true
    }

    /// Copies `region` into a small sRGB image, padding outside the screen with black.
    private static func sample(_ image: CGImage, region: PixelRect) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: region.width, height: region.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: region.width, height: region.height))
        let visible = region.clamped(width: image.width, height: image.height)
        guard !visible.isEmpty, let crop = image.cropping(to: visible.cgRect) else { return context.makeImage() }
        context.interpolationQuality = .none
        // Context space is y-up: place the crop relative to the region's bottom edge.
        let x = visible.x - region.x
        let yFromTop = visible.y - region.y
        let y = region.height - yFromTop - visible.height
        context.draw(crop, in: CGRect(x: x, y: y, width: visible.width, height: visible.height))
        return context.makeImage()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let radius: CGFloat = 18
        let shape = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.addPath(shape)
        context.clip()
        if let pixels {
            context.interpolationQuality = .none
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(pixels, in: bounds)
            context.restoreGState()
        }
        let cell = bounds.width / CGFloat(cells)
        context.setStrokeColor(CGColor(gray: 0.5, alpha: 0.25))
        context.setLineWidth(0.5)
        for index in 1..<cells {
            let offset = CGFloat(index) * cell
            context.move(to: CGPoint(x: offset, y: 0))
            context.addLine(to: CGPoint(x: offset, y: bounds.height))
            context.move(to: CGPoint(x: 0, y: offset))
            context.addLine(to: CGPoint(x: bounds.width, y: offset))
        }
        context.strokePath()
        let center = CGRect(x: CGFloat(cells / 2) * cell, y: CGFloat(cells / 2) * cell, width: cell, height: cell)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.9))
        context.setLineWidth(2.5)
        context.stroke(center.insetBy(dx: -0.5, dy: -0.5))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(1.2)
        context.stroke(center.insetBy(dx: -0.5, dy: -0.5))
        context.restoreGState()

        context.addPath(shape)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
        context.setLineWidth(2)
        context.strokePath()
        context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), cornerWidth: radius + 0.5, cornerHeight: radius + 0.5, transform: nil))
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.35))
        context.setLineWidth(0.5)
        context.strokePath()
    }
}

/// Small glass capsule with one line of text.
struct GlassLabel: View {
    let text: String
    var secondary = false

    var body: some View {
        Text(text)
            .font(.system(size: secondary ? 12 : 12.5, weight: secondary ? .medium : .semibold))
            .monospacedDigit()
            .foregroundStyle(secondary ? .secondary : .primary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .padding(8)
            .fixedSize()
    }
}

/// Loupe caption: coordinates, color value and optional contrast ratio.
struct InfoPill: View {
    let lines: [String]
    var swatch: RGBAColor?

    var body: some View {
        HStack(spacing: 8) {
            if let swatch {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(swatch))
                    .frame(width: 14, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.7), lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.system(size: 11, weight: index == 1 ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(index == 1 ? .primary : .secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .padding(6)
        .fixedSize()
    }
}
