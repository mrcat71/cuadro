import AppKit
import SwiftUI

/// Zoomable, pannable container for the canvas.
final class CanvasScrollView: NSScrollView {
    let canvas: CanvasView
    private let model: EditorModel
    /// While set, the canvas is fitted again (never above this zoom) whenever the view changes size,
    /// so the fit follows the window to its final size and through resizes. Zooming by hand clears it.
    private var fitMaximum: CGFloat? = 1
    private var fittedSize: CGSize = .zero
    private var didFocusCanvas = false

    init(model: EditorModel) {
        self.model = model
        canvas = CanvasView(model: model)
        super.init(frame: .zero)
        let clip = CenteringClipView()
        clip.drawsBackground = false
        contentView = clip
        documentView = canvas
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = 0.05
        maxMagnification = 32
        drawsBackground = true
        backgroundColor = .underPageBackgroundColor
        automaticallyAdjustsContentInsets = false

        model.onCanvasChange = { [weak self] in self?.canvas.modelChanged() }
        model.onZoomCommand = { [weak self] command in self?.perform(command) }
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyStarted), name: NSScrollView.willStartLiveMagnifyNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(magnificationChanged), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        guard bounds.width > 100, bounds.height > 100 else { return }
        if !didFocusCanvas {
            didFocusCanvas = true
            window?.makeFirstResponder(canvas)
        }
        // The first layout runs at the hosting view's minimum size, before the window gets its
        // real frame; fitting only once there left captures at a fraction of the window.
        if let fitMaximum, bounds.size != fittedSize {
            fittedSize = bounds.size
            zoomToFit(maximum: fitMaximum)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        fitMaximum = nil
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        let point = canvas.convert(event.locationInWindow, from: nil)
        setMagnification(magnification * pow(1.01, delta), centeredAt: point)
        magnificationChanged()
    }

    override func smartMagnify(with event: NSEvent) {
        fitMaximum = nil
        super.smartMagnify(with: event)
    }

    func perform(_ command: ZoomCommand) {
        let center = CGPoint(x: canvas.visibleRect.midX, y: canvas.visibleRect.midY)
        fitMaximum = nil
        switch command {
        case .zoomIn: setMagnification(magnification * 1.25, centeredAt: center)
        case .zoomOut: setMagnification(magnification / 1.25, centeredAt: center)
        case .actualSize: setMagnification(1, centeredAt: center)
        case .fit:
            fitMaximum = 8
            zoomToFit(maximum: 8)
        }
        magnificationChanged()
    }

    /// Fits the canvas between the floating toolbars, never enlarging beyond `maximum`.
    func zoomToFit(maximum: CGFloat) {
        let size = canvas.frame.size
        guard size.width > 0, size.height > 0 else { return }
        let available = CGSize(width: max(bounds.width - 48, 100), height: max(bounds.height - 176, 100))
        let fit = min(available.width / size.width, available.height / size.height, maximum)
        setMagnification(max(fit, minMagnification), centeredAt: CGPoint(x: size.width / 2, y: size.height / 2))
        magnificationChanged()
    }

    @objc private func liveMagnifyStarted() {
        fitMaximum = nil
    }

    @objc private func magnificationChanged() {
        model.zoom = magnification
        canvas.needsDisplay = true
    }
}

/// Keeps the document centered when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView, rect.width > 0, frame.width > 0 else { return rect }
        let document = documentView.frame
        // Snap the centered origin to whole device pixels: half a pixel off blurs a canvas shown at
        // 100% on a 1x display.
        let pixelsPerPoint = (window?.backingScaleFactor ?? 2) * frame.width / rect.width
        if rect.width > document.width {
            rect.origin.x = ((document.midX - rect.width / 2) * pixelsPerPoint).rounded() / pixelsPerPoint
        }
        if rect.height > document.height {
            rect.origin.y = ((document.midY - rect.height / 2) * pixelsPerPoint).rounded() / pixelsPerPoint
        }
        return rect
    }
}

struct CanvasRepresentable: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> CanvasScrollView {
        CanvasScrollView(model: model)
    }

    func updateNSView(_ nsView: CanvasScrollView, context: Context) {}
}
