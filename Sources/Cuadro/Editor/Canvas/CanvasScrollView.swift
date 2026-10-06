import AppKit
import SwiftUI

/// Zoomable, pannable container for the canvas.
final class CanvasScrollView: NSScrollView {
    let canvas: CanvasView
    private let model: EditorModel
    private var didInitialZoom = false

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
        NotificationCenter.default.addObserver(self, selector: #selector(magnificationChanged), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        if !didInitialZoom, bounds.width > 100, bounds.height > 100 {
            didInitialZoom = true
            zoomToFit(maximum: 1)
            window?.makeFirstResponder(canvas)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        let point = canvas.convert(event.locationInWindow, from: nil)
        setMagnification(magnification * pow(1.01, delta), centeredAt: point)
        magnificationChanged()
    }

    func perform(_ command: ZoomCommand) {
        let center = CGPoint(x: canvas.visibleRect.midX, y: canvas.visibleRect.midY)
        switch command {
        case .zoomIn: setMagnification(magnification * 1.25, centeredAt: center)
        case .zoomOut: setMagnification(magnification / 1.25, centeredAt: center)
        case .actualSize: setMagnification(1, centeredAt: center)
        case .fit: zoomToFit(maximum: 8)
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

    @objc private func magnificationChanged() {
        model.zoom = magnification
        canvas.needsDisplay = true
    }
}

/// Keeps the document centered when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let frame = documentView.frame
        if rect.width > frame.width { rect.origin.x = frame.midX - rect.width / 2 }
        if rect.height > frame.height { rect.origin.y = frame.midY - rect.height / 2 }
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
