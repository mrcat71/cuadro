import AppKit
import Carbon.HIToolbox
import CuadroKit

/// The editable screenshot: draws through `DocumentRenderer` and handles every tool.
/// Coordinates: the view is flipped and sized to the canvas layout (points); document points
/// map to canvas points through `CanvasLayout`.
final class CanvasView: NSView, NSTextViewDelegate {
    let model: EditorModel
    private(set) var layoutInfo: CanvasLayout

    private enum Interaction {
        case idle
        case creating(origin: CGPoint)
        case moving(id: UUID, last: CGPoint, before: DocumentState, moved: Bool)
        case resizing(id: UUID, handle: AnnotationHandle, before: DocumentState)
        case panning(last: CGPoint)
        case cropNew(origin: CGPoint)
        case cropMove(last: CGPoint)
        case cropResize(handle: RectHandle)
    }

    private var interaction: Interaction = .idle
    private var spaceDown = false
    private var trackingArea: NSTrackingArea?
    private var textContainer: NSView?
    private var textView: AnnotationTextView?

    init(model: EditorModel) {
        self.model = model
        layoutInfo = model.renderer.layout(for: model.document)
        super.init(frame: CGRect(origin: .zero, size: layoutInfo.canvasSize))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }
    private var handleRadius: CGFloat { 7 / magnification }
    private var hitTolerance: CGFloat { 5 / magnification }

    private var renderOptions: RenderOptions {
        RenderOptions(hiddenAnnotationID: model.editingTextID, showsFullImage: model.tool == .crop)
    }

    /// Called whenever the model changes something visible.
    func modelChanged() {
        let layout = model.renderer.layout(for: model.document, options: renderOptions)
        if layout != layoutInfo || frame.size != layout.canvasSize {
            layoutInfo = layout
            setFrameSize(layout.canvasSize)
            positionTextEditor()
        }
        if model.editingTextID == nil, textView != nil {
            removeTextEditor()
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pixelZoom = magnification / model.scale
        ctx.interpolationQuality = pixelZoom >= 2 ? .none : .high

        var document = model.document
        if let draft = model.draft { document.annotations.append(draft) }
        model.renderer.draw(document, in: ctx, options: renderOptions)

        ctx.saveGState()
        ctx.concatenate(layoutInfo.documentToCanvas)
        if model.tool == .crop {
            drawCropChrome(ctx)
        } else {
            drawSelection(ctx)
            drawRulerHover(ctx)
        }
        ctx.restoreGState()

        if pixelZoom >= 6 {
            drawPixelGrid(ctx, dirtyRect: dirtyRect)
        }
    }

    private func drawSelection(_ ctx: CGContext) {
        guard let selected = model.selectedAnnotation, model.editingTextID != selected.id else { return }
        let line = 1 / magnification
        let accent = NSColor.controlAccentColor.cgColor
        ctx.saveGState()
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(line)
        ctx.setLineDash(phase: 0, lengths: [4 * line, 3 * line])
        if selected.kind.isSegment {
            ctx.addLines(between: selected.centerline)
        } else {
            ctx.addRect(selected.bounds.insetBy(dx: -3 * line, dy: -3 * line))
        }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        for (handle, point) in selected.handles {
            let radius = (handle == .bend ? 4.5 : 5) * line
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            ctx.setFillColor(handle == .bend ? accent : CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(handle == .bend ? CGColor(gray: 1, alpha: 1) : accent)
            ctx.setLineWidth(1.5 * line)
            ctx.strokeEllipse(in: rect)
        }
        ctx.restoreGState()
    }

    private func drawRulerHover(_ ctx: CGContext) {
        guard model.tool == .ruler, let hover = model.rulerHover, case .idle = interaction else { return }
        let line = 1 / magnification
        let color = NSColor.systemPink.cgColor
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1.5 * line)
        for segment in [hover.horizontal, hover.vertical].compactMap({ $0 }) {
            ctx.move(to: segment.0)
            ctx.addLine(to: segment.1)
        }
        ctx.strokePath()
        let font = TextLayout.font(size: 11 * line, weight: 0.4)
        for segment in [hover.horizontal, hover.vertical].compactMap({ $0 }) {
            let label = model.renderer.measurementLabel(points: segment.0.distance(to: segment.1))
            let size = TextLayout.lineSize(label, font: font)
            let mid = segment.0.midpoint(segment.1)
            let pill = CGRect(x: mid.x - size.width / 2 - 5 * line, y: mid.y - size.height / 2 - 3 * line, width: size.width + 10 * line, height: size.height + 6 * line)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
            ctx.setFillColor(color)
            ctx.fillPath()
            TextLayout.drawCentered(label, font: font, color: .white, center: mid, in: ctx)
        }
        ctx.restoreGState()
    }

    private func drawCropChrome(_ ctx: CGContext) {
        guard let crop = model.cropRect else { return }
        let line = 1 / magnification
        ctx.saveGState()
        let dim = CGMutablePath()
        dim.addRect(model.imageBounds)
        dim.addRect(crop)
        ctx.addPath(dim)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fillPath(using: .evenOdd)

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.45))
        ctx.setLineWidth(line)
        for index in 1...2 {
            let x = crop.minX + crop.width * CGFloat(index) / 3
            let y = crop.minY + crop.height * CGFloat(index) / 3
            ctx.move(to: CGPoint(x: x, y: crop.minY))
            ctx.addLine(to: CGPoint(x: x, y: crop.maxY))
            ctx.move(to: CGPoint(x: crop.minX, y: y))
            ctx.addLine(to: CGPoint(x: crop.maxX, y: y))
        }
        ctx.strokePath()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(1.5 * line)
        ctx.stroke(crop)

        // L-shaped corner grips.
        let arm = min(18 * line, crop.width / 3, crop.height / 3)
        ctx.setLineWidth(4 * line)
        ctx.setLineCap(.round)
        for handle in [RectHandle.topLeft, .topRight, .bottomRight, .bottomLeft] {
            let point = handle.point(in: crop)
            let dx: CGFloat = handle == .topLeft || handle == .bottomLeft ? arm : -arm
            let dy: CGFloat = handle == .topLeft || handle == .topRight ? arm : -arm
            ctx.move(to: CGPoint(x: point.x + dx, y: point.y))
            ctx.addLine(to: point)
            ctx.addLine(to: CGPoint(x: point.x, y: point.y + dy))
        }
        ctx.strokePath()

        let label = "\(Int((crop.width * model.scale).rounded())) × \(Int((crop.height * model.scale).rounded())) px"
        let font = TextLayout.font(size: 11 * line, weight: 0.4)
        let size = TextLayout.lineSize(label, font: font)
        let center = CGPoint(x: crop.midX, y: crop.maxY + 16 * line)
        let pill = CGRect(x: center.x - size.width / 2 - 6 * line, y: center.y - size.height / 2 - 3 * line, width: size.width + 12 * line, height: size.height + 6 * line)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.7))
        ctx.fillPath()
        TextLayout.drawCentered(label, font: font, color: .white, center: center, in: ctx)
        ctx.restoreGState()
    }

    private func drawPixelGrid(_ ctx: CGContext, dirtyRect: CGRect) {
        let image = layoutInfo.imageRect
        let area = dirtyRect.intersection(image)
        guard !area.isNull else { return }
        let step = 1 / model.scale
        let originX = image.minX - layoutInfo.cropRect.minX
        let originY = image.minY - layoutInfo.cropRect.minY
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 0.35))
        ctx.setLineWidth(0.5 / magnification)
        var x = originX + ((area.minX - originX) / step).rounded(.down) * step
        while x <= area.maxX {
            ctx.move(to: CGPoint(x: x, y: area.minY))
            ctx.addLine(to: CGPoint(x: x, y: area.maxY))
            x += step
        }
        var y = originY + ((area.minY - originY) / step).rounded(.down) * step
        while y <= area.maxY {
            ctx.move(to: CGPoint(x: area.minX, y: y))
            ctx.addLine(to: CGPoint(x: area.maxX, y: y))
            y += step
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private func documentPoint(_ event: NSEvent) -> CGPoint {
        layoutInfo.documentPoint(fromCanvas: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = documentPoint(event)
        model.updateCursor(at: point)
        if model.tool == .ruler { model.updateRulerHover(at: point) }
        updateCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        model.updateCursor(at: nil)
        model.updateRulerHover(at: nil)
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        if textView != nil {
            // A click outside the text only finishes editing.
            commitTextEditing()
            return
        }
        window?.makeFirstResponder(self)
        let point = documentPoint(event)

        if spaceDown || event.buttonNumber == 2 {
            interaction = .panning(last: event.locationInWindow)
            NSCursor.closedHand.set()
            return
        }

        switch model.tool {
        case .crop:
            cropMouseDown(at: point)
            return
        case .picker:
            model.pickColor(at: point)
            return
        default:
            break
        }

        let before = model.document
        if let selected = model.selectedAnnotation, let handle = selected.handle(at: point, radius: handleRadius) {
            interaction = .resizing(id: selected.id, handle: handle, before: before)
            return
        }
        if let hit = model.topAnnotation(at: point, tolerance: hitTolerance) {
            if event.clickCount >= 2, hit.kind == .text {
                startTextEditing(hit.id)
                return
            }
            model.selectedID = hit.id
            interaction = .moving(id: hit.id, last: point, before: before, moved: false)
            return
        }

        model.selectedID = nil
        switch model.tool {
        case .select:
            break
        case .text:
            let id = model.beginNewText(at: point)
            startTextEditing(id, isNew: true)
        case .counter:
            model.addCounter(at: point)
        case .ruler where event.modifierFlags.contains(.option):
            model.stampRulerHover()
        default:
            guard let kind = model.kind(for: model.tool) else { return }
            var annotation = Annotation(kind: kind, start: point, end: point, style: model.style(for: model.tool))
            if kind == .pen { annotation.points = [point] }
            model.draft = annotation
            interaction = .creating(origin: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = documentPoint(event)
        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)
        switch interaction {
        case .idle:
            break
        case .creating(let origin):
            guard var draft = model.draft else { return }
            if draft.kind.isSegment {
                draft.end = shift ? Geometry.snapAngle(from: origin, to: point) : point
            } else if draft.kind == .pen {
                if let last = draft.points.last, last.distance(to: point) >= 0.75 / magnification {
                    draft.points.append(point)
                }
            } else {
                let rect = Geometry.dragRect(from: origin, to: point, square: shift || draft.kind == .magnifier, fromCenter: option)
                draft.start = CGPoint(x: rect.minX, y: rect.minY)
                draft.end = CGPoint(x: rect.maxX, y: rect.maxY)
                if draft.kind == .erase { draft.fillColor = model.fillColor(for: rect) }
            }
            model.draft = draft
        case .moving(let id, let last, let before, _):
            model.mutateAnnotation(id) { $0.translate(by: point - last) }
            interaction = .moving(id: id, last: point, before: before, moved: true)
        case .resizing(let id, let handle, _):
            model.mutateAnnotation(id) { $0.move(handle, to: point, constrained: shift) }
        case .panning(let last):
            pan(by: CGPoint(x: event.locationInWindow.x - last.x, y: event.locationInWindow.y - last.y))
            interaction = .panning(last: event.locationInWindow)
        case .cropNew(let origin):
            var rect = Geometry.dragRect(from: origin, to: point, square: shift, fromCenter: option)
            if let ratio = model.cropAspectRatio {
                rect = RectHandle.bottomRight.resize(CGRect(origin: origin, size: .zero), to: point, aspect: ratio)
            }
            model.cropRect = rect.intersection(model.imageBounds)
        case .cropMove(let last):
            guard let crop = model.cropRect else { return }
            model.cropRect = crop.offsetBy(dx: point.x - last.x, dy: point.y - last.y).constrained(to: model.imageBounds)
            interaction = .cropMove(last: point)
        case .cropResize(let handle):
            guard let crop = model.cropRect else { return }
            let aspect = model.cropAspectRatio ?? (shift ? crop.width / max(crop.height, 1) : nil)
            let resized = handle.resize(crop, to: point, aspect: aspect).intersection(model.imageBounds)
            if !resized.isNull { model.cropRect = resized }
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch interaction {
        case .creating:
            if let draft = model.draft {
                model.draft = nil
                if !draft.isDegenerate {
                    model.add(draft)
                }
            }
        case .moving(let id, _, let before, let moved):
            if moved {
                model.refreshEraseFill(id)
                model.registerUndo(before, "Move")
            }
        case .resizing(let id, _, let before):
            model.refreshEraseFill(id)
            model.registerUndo(before, "Resize")
        case .panning:
            NSCursor.openHand.set()
        case .cropNew:
            if let crop = model.cropRect, crop.width < 2 || crop.height < 2 {
                model.resetCrop()
            }
        default:
            break
        }
        interaction = .idle
        updateCursor(at: documentPoint(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = documentPoint(event)
        guard let hit = model.topAnnotation(at: point, tolerance: hitTolerance) else {
            super.rightMouseDown(with: event)
            return
        }
        model.selectedID = hit.id
        let menu = NSMenu()
        menu.addItem(withTitle: "Duplicate", action: #selector(duplicateSelection), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Bring to Front", action: #selector(bringToFront), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Send to Back", action: #selector(sendToBack), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(deleteSelection), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func duplicateSelection() { model.duplicateSelection() }
    @objc private func bringToFront() { model.reorderSelection(toFront: true) }
    @objc private func sendToBack() { model.reorderSelection(toFront: false) }
    @objc private func deleteSelection() { model.deleteSelection() }

    private func cropMouseDown(at point: CGPoint) {
        guard let crop = model.cropRect else {
            interaction = .cropNew(origin: point)
            return
        }
        let radius = 12 / magnification
        if let handle = RectHandle.allCases.first(where: { $0.point(in: crop).distance(to: point) <= radius }) {
            interaction = .cropResize(handle: handle)
        } else if crop.contains(point) {
            interaction = .cropMove(last: point)
        } else {
            interaction = .cropNew(origin: point)
        }
    }

    private func pan(by delta: CGPoint) {
        guard let clip = enclosingScrollView?.contentView else { return }
        var origin = clip.bounds.origin
        origin.x -= delta.x / magnification
        origin.y += delta.y / magnification
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    private func updateCursor(at point: CGPoint) {
        if spaceDown {
            NSCursor.openHand.set()
            return
        }
        switch model.tool {
        case .crop:
            if let crop = model.cropRect, crop.contains(point) { NSCursor.openHand.set() } else { NSCursor.crosshair.set() }
            return
        case .picker:
            NSCursor.crosshair.set()
            return
        default:
            break
        }
        if let selected = model.selectedAnnotation, selected.handle(at: point, radius: handleRadius) != nil {
            NSCursor.crosshair.set()
        } else if model.topAnnotation(at: point, tolerance: hitTolerance) != nil {
            NSCursor.openHand.set()
        } else if model.tool == .text {
            NSCursor.iBeam.set()
        } else if model.tool == .select {
            NSCursor.arrow.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_Space:
            if !event.isARepeat {
                spaceDown = true
                NSCursor.openHand.set()
            }
            return
        case kVK_Delete, kVK_ForwardDelete:
            model.deleteSelection()
            return
        case kVK_Escape:
            if model.tool == .crop {
                model.cancelCrop()
            } else if model.selectedID != nil {
                model.selectedID = nil
            }
            return
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if model.tool == .crop {
                model.applyCrop()
            } else if let selected = model.selectedAnnotation, selected.kind == .text {
                startTextEditing(selected.id)
            }
            return
        case kVK_LeftArrow: model.nudgeSelection(by: CGPoint(x: -step, y: 0)); return
        case kVK_RightArrow: model.nudgeSelection(by: CGPoint(x: step, y: 0)); return
        case kVK_UpArrow: model.nudgeSelection(by: CGPoint(x: 0, y: -step)); return
        case kVK_DownArrow: model.nudgeSelection(by: CGPoint(x: 0, y: step)); return
        default:
            break
        }
        if flags.isDisjoint(with: [.command, .control, .option]), let character = event.charactersIgnoringModifiers?.lowercased().first {
            if let digit = character.wholeNumberValue, (1...9).contains(digit),
               model.tool == .spotlight || model.selectedAnnotation?.kind == .spotlight {
                model.setSpotlightOpacity(Double(digit) / 10)
                return
            }
            if let tool = EditorTool.forKey(character) {
                model.tool = tool
                return
            }
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Space {
            spaceDown = false
            NSCursor.arrow.set()
        }
        super.keyUp(with: event)
    }

    // MARK: Inline text editing

    private func startTextEditing(_ id: UUID, isNew: Bool = false) {
        guard let annotation = model.document.annotation(withID: id) else { return }
        if !isNew { model.beginEditingText(id) }
        removeTextEditor()

        let style = annotation.style
        let container = NSView()
        container.wantsLayer = true
        if style.textStyle == .pill {
            container.layer?.backgroundColor = style.color.cgColor
        }
        let textView = AnnotationTextView()
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        let padding = TextLayout.padding(for: style)
        textView.textContainerInset = NSSize(width: padding.width, height: padding.height)
        textView.font = unsafeBitCast(TextLayout.font(size: style.fontSize), to: NSFont.self)
        let color = style.textStyle == .pill ? style.color.contrastingTextColor : style.color
        textView.textColor = NSColor(color)
        textView.insertionPointColor = NSColor(color)
        textView.string = annotation.text
        textView.onCommit = { [weak self] in self?.commitTextEditing() }
        container.addSubview(textView)
        addSubview(container)
        textContainer = container
        self.textView = textView
        positionTextEditor()
        window?.makeFirstResponder(textView)
        textView.selectAll(nil)
    }

    private func positionTextEditor() {
        guard let container = textContainer, let textView, let id = model.editingTextID,
              let annotation = model.document.annotation(withID: id) else { return }
        let size = TextLayout.size(of: textView.string.isEmpty ? " " : textView.string, style: annotation.style)
        let origin = layoutInfo.canvasPoint(fromDocument: annotation.start)
        container.frame = CGRect(origin: origin, size: CGSize(width: size.width + 2, height: size.height))
        container.layer?.cornerRadius = annotation.style.textStyle == .pill ? min(size.height / 2, annotation.style.fontSize * 0.5) : 0
        textView.frame = container.bounds
    }

    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        model.updateEditingText(textView.string)
        positionTextEditor()
    }

    private func commitTextEditing() {
        guard let textView else { return }
        let text = textView.string
        removeTextEditor()
        model.endEditingText(text)
        window?.makeFirstResponder(self)
    }

    private func removeTextEditor() {
        textView?.delegate = nil
        textContainer?.removeFromSuperview()
        textContainer = nil
        textView = nil
    }

    /// Ends inline editing, e.g. before the window closes or exports.
    func finishEditing() {
        if textView != nil { commitTextEditing() }
    }
}

/// Text view used for inline editing; Escape or Command-Return commits.
final class AnnotationTextView: NSTextView {
    var onCommit: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCommit?()
    }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Return, event.modifierFlags.contains(.command) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }
}
