import AppKit
import Carbon.HIToolbox
import CuadroKit

enum OverlayMode {
    case area, window, picker, ruler
}

/// What happens with an area once it is selected.
enum CaptureIntent {
    case capture, recognizeText, scrolling, pin, record

    /// Clicking a window or switching to window mode makes sense for this intent.
    var selectsWindows: Bool { self == .capture || self == .pin || self == .record }
    /// Return takes the whole display.
    var takesWholeDisplay: Bool { self == .capture || self == .record }
}

enum OverlayOutcome {
    /// Display-local y-down rect in points.
    case area(DisplaySnapshot, CGRect)
    case window(WindowInfo)
    case display(DisplaySnapshot)
    /// Picker and ruler sessions that already did their job.
    case finished
    case cancelled
}

private enum RulerAxis {
    case both, horizontal, vertical
}

/// Drives the frozen-screen overlay on every display: area and window selection, the color
/// picker and the screen ruler.
final class OverlayController {
    let intent: CaptureIntent
    private(set) var mode: OverlayMode

    private let snapshots: [DisplaySnapshot]
    private let windows: [WindowInfo]
    private let completion: (OverlayOutcome) -> Void
    private var panels: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var isFinished = false

    private var activeView: OverlayView?
    private var pointer: CGPoint = .zero
    private var dragOrigin: CGPoint?
    private var lastDragPoint: CGPoint?
    private var selection: CGRect?
    private var isDragging = false
    private var spaceHeld = false
    private var hoveredWindow: WindowInfo?

    private var pixelBuffers: [CGDirectDisplayID: PixelBuffer] = [:]
    private var pixelTasks: [Task<Void, Never>] = []
    private var referenceColor: RGBAColor?
    private var rulerTolerance = 10
    private var rulerAxis: RulerAxis = .both

    private let settings = AppSettings.shared

    init(snapshots: [DisplaySnapshot], windows: [WindowInfo], mode: OverlayMode, intent: CaptureIntent, completion: @escaping (OverlayOutcome) -> Void) {
        self.snapshots = snapshots
        self.windows = windows
        self.mode = mode
        self.intent = intent
        self.completion = completion
    }

    func begin() {
        for snapshot in snapshots {
            guard let screen = NSScreen.screen(for: snapshot.displayID) else { continue }
            let panel = OverlayWindow(screen: screen)
            let view = OverlayView(snapshot: snapshot, controller: self)
            panel.contentView = view
            panels.append(panel)
            views.append(view)
        }
        guard !panels.isEmpty else {
            finish(.cancelled)
            return
        }
        for panel in panels {
            panel.orderFrontRegardless()
        }
        NSApp.activate()

        let mouse = NSEvent.mouseLocation
        let index = panels.firstIndex { NSMouseInRect(mouse, $0.frame, false) } ?? 0
        if views.indices.contains(index) {
            activeView = views[index]
            panels[index].makeKey()
            panels[index].makeFirstResponder(views[index])
            pointer = views[index].localPoint(fromGlobal: mouse)
        }
        if mode == .picker || mode == .ruler {
            preparePixelBuffers()
        }
        if mode == .window, let view = activeView {
            hoveredWindow = window(at: view.globalPoint(fromLocal: pointer))
        }
        NSCursor.crosshair.set()
        refresh()
    }

    func cancel() {
        finish(mode == .ruler || mode == .picker ? .finished : .cancelled)
    }

    /// Development aid for `--ui-snapshot`: shows a selection as if it were being dragged.
    func debugSelect(_ rect: CGRect, pointer: CGPoint) {
        guard let view = activeView ?? views.first else { return }
        activeView = view
        dragOrigin = rect.origin
        self.pointer = pointer
        selection = rect
        isDragging = true
        refresh()
    }

    private func finish(_ outcome: OverlayOutcome) {
        guard !isFinished else { return }
        isFinished = true
        for task in pixelTasks { task.cancel() }
        let closing = panels
        for panel in closing {
            panel.orderOut(nil)
        }
        // Tear the views down after the current event finishes dispatching to them.
        Task { @MainActor in
            for panel in closing { panel.contentView = nil }
        }
        panels.removeAll()
        views.removeAll()
        activeView = nil
        NSCursor.arrow.set()
        completion(outcome)
    }

    // MARK: Pointer

    private func activate(_ view: OverlayView) {
        guard activeView !== view else { return }
        activeView = view
        view.window?.makeKey()
        view.window?.makeFirstResponder(view)
        selection = nil
        dragOrigin = nil
        isDragging = false
    }

    func pointerMoved(in view: OverlayView, to point: CGPoint) {
        activate(view)
        pointer = clamped(point, in: view)
        if mode == .window {
            hoveredWindow = window(at: view.globalPoint(fromLocal: pointer))
        }
        refresh()
    }

    func pointerDown(in view: OverlayView, at point: CGPoint, event: NSEvent) {
        activate(view)
        pointer = clamped(point, in: view)
        switch mode {
        case .area, .ruler:
            dragOrigin = snapped(pointer, scale: view.snapshot.scale)
            lastDragPoint = pointer
            selection = nil
            isDragging = true
        case .window:
            break
        case .picker:
            if event.modifierFlags.contains(.shift) {
                referenceColor = color(at: pointer, in: view)
                refresh()
            } else {
                copyColorUnderPointer()
                finish(.finished)
            }
        }
        refresh()
    }

    func pointerDragged(in view: OverlayView, to point: CGPoint, event: NSEvent) {
        guard isDragging, view === activeView else { return }
        let current = clamped(point, in: view)
        if spaceHeld, let last = lastDragPoint, let origin = dragOrigin {
            // Space moves the whole selection instead of resizing it.
            dragOrigin = origin + (current - last)
        }
        lastDragPoint = current
        pointer = current
        updateSelection(event.modifierFlags)
        refresh()
    }

    func pointerUp(in view: OverlayView, at point: CGPoint, event: NSEvent) {
        let global = view.globalPoint(fromLocal: clamped(point, in: view))
        switch mode {
        case .window:
            if let target = hoveredWindow ?? window(at: global) {
                completeWindowSelection(target, in: view)
            }
        case .area:
            guard isDragging else { return }
            isDragging = false
            spaceHeld = false
            if let selection, selection.width >= 3, selection.height >= 3 {
                finish(.area(view.snapshot, selection.snapped(toScale: view.snapshot.scale)))
            } else if let target = window(at: global), intent.selectsWindows {
                // A click without dragging takes the window under the pointer.
                completeWindowSelection(target, in: view)
            } else {
                selection = nil
                refresh()
            }
        case .ruler:
            isDragging = false
            if let selection, selection.width >= 2 || selection.height >= 2 {
                let text = measurementText(width: selection.width, height: selection.height, scale: view.snapshot.scale)
                Pasteboard.copy(text: text)
                ToastCenter.shared.show("Copied \(text)", symbol: "ruler")
            } else {
                selection = nil
                copyHoverMeasurement()
            }
            refresh()
        case .picker:
            break
        }
    }

    private func completeWindowSelection(_ target: WindowInfo, in view: OverlayView) {
        switch intent {
        case .capture:
            finish(.window(target))
        case .pin, .recognizeText, .scrolling, .record:
            // Use the window's on-screen area from the frozen image.
            let local = view.localRect(fromGlobal: target.frame).intersection(view.bounds)
            guard !local.isNull, local.width >= 3, local.height >= 3 else { return }
            finish(.area(view.snapshot, local.snapped(toScale: view.snapshot.scale)))
        }
    }

    private func updateSelection(_ flags: NSEvent.ModifierFlags) {
        guard let origin = dragOrigin, let view = activeView else { return }
        let target = snapped(pointer, scale: view.snapshot.scale)
        let rect = Geometry.dragRect(
            from: origin, to: target,
            square: flags.contains(.shift), fromCenter: flags.contains(.option)
        ).intersection(view.bounds)
        selection = rect.isNull ? nil : rect
    }

    // MARK: Keyboard

    func keyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_Escape:
            cancel()
        case kVK_Space:
            guard !event.isARepeat else { return true }
            if isDragging {
                spaceHeld = true
            } else if mode == .area || mode == .window, intent.selectsWindows {
                mode = mode == .area ? .window : .area
                selection = nil
                if mode == .window, let view = activeView {
                    hoveredWindow = window(at: view.globalPoint(fromLocal: pointer))
                } else {
                    hoveredWindow = nil
                }
                refresh()
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if intent.takesWholeDisplay, mode == .area || mode == .window, let view = activeView {
                finish(.display(view.snapshot))
            }
        case kVK_Tab:
            copyColorUnderPointer()
            if mode != .ruler, mode != .picker { finish(.finished) }
        case kVK_UpArrow, kVK_DownArrow:
            if mode == .ruler {
                rulerAxis = rulerAxis == .vertical ? .both : .vertical
                refresh()
            } else {
                nudge(dx: 0, dy: Int(event.keyCode) == kVK_UpArrow ? -step : step)
            }
        case kVK_LeftArrow, kVK_RightArrow:
            if mode == .ruler {
                rulerAxis = rulerAxis == .horizontal ? .both : .horizontal
                refresh()
            } else {
                nudge(dx: Int(event.keyCode) == kVK_LeftArrow ? -step : step, dy: 0)
            }
        case kVK_ANSI_C where flags.contains(.command):
            if mode == .ruler { copyHoverMeasurement() } else { copyColorUnderPointer() }
        default:
            return false
        }
        return true
    }

    func keyUp(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Space { spaceHeld = false }
    }

    func flagsChanged(_ event: NSEvent) {
        guard isDragging, mode == .area || mode == .ruler else { return }
        updateSelection(event.modifierFlags)
        refresh()
    }

    func scrollWheel(_ event: NSEvent) {
        guard mode == .ruler else { return }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.5 else { return }
        rulerTolerance = max(0, min(128, rulerTolerance + (delta > 0 ? 2 : -2)))
        refresh()
    }

    /// Moves the pointer by whole points for precise selections.
    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard let view = activeView else { return }
        pointer = clamped(CGPoint(x: pointer.x + dx, y: pointer.y + dy), in: view)
        let global = view.globalPoint(fromLocal: pointer)
        CGWarpMouseCursorPosition(ScreenCoordinates(primaryScreenHeight: NSScreen.primaryHeight).flip(global))
        if isDragging { updateSelection(NSEvent.modifierFlags) }
        if mode == .window { hoveredWindow = window(at: global) }
        refresh()
    }

    // MARK: Colors and measurements

    private func pixel(of point: CGPoint, in view: OverlayView) -> (Int, Int) {
        let scale = view.snapshot.scale
        return (Int((point.x * scale).rounded(.down)), Int((point.y * scale).rounded(.down)))
    }

    private func color(at point: CGPoint, in view: OverlayView) -> RGBAColor? {
        let (x, y) = pixel(of: point, in: view)
        let image = view.snapshot.image
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        return PixelBuffer(image: image, region: PixelRect(x: x, y: y, width: 1, height: 1))?.color(x: 0, y: 0)
    }

    private func copyColorUnderPointer() {
        guard let view = activeView, let color = color(at: pointer, in: view) else { return }
        let text = color.string(in: settings.colorFormat)
        Pasteboard.copy(text: text)
        ToastCenter.shared.show("Copied \(text)", swatch: color)
    }

    private func copyHoverMeasurement() {
        guard let view = activeView, let span = rulerSpan(in: view) else { return }
        let scale = view.snapshot.scale
        let text: String
        switch rulerAxis {
        case .both: text = measurementText(width: CGFloat(span.width) / scale, height: CGFloat(span.height) / scale, scale: scale)
        case .horizontal: text = lengthText(CGFloat(span.width) / scale, scale: scale)
        case .vertical: text = lengthText(CGFloat(span.height) / scale, scale: scale)
        }
        Pasteboard.copy(text: text)
        ToastCenter.shared.show("Copied \(text)", symbol: "ruler")
    }

    private func rulerSpan(in view: OverlayView) -> EdgeSpan? {
        guard let buffer = pixelBuffers[view.snapshot.displayID] else { return nil }
        let (x, y) = pixel(of: pointer, in: view)
        return EdgeFinder.span(in: buffer, x: x, y: y, tolerance: rulerTolerance)
    }

    private func unit(for scale: CGFloat) -> String { scale == 1 ? "px" : "pt" }

    private func lengthText(_ value: CGFloat, scale: CGFloat) -> String {
        "\(Int(value.rounded())) \(unit(for: scale))"
    }

    private func measurementText(width: CGFloat, height: CGFloat, scale: CGFloat) -> String {
        "\(Int(width.rounded())) × \(Int(height.rounded())) \(unit(for: scale))"
    }

    private func preparePixelBuffers() {
        for snapshot in snapshots {
            let image = snapshot.image
            let id = snapshot.displayID
            pixelTasks.append(Task { [weak self] in
                let buffer = await Task.detached(priority: .userInitiated) { PixelBuffer(image: image) }.value
                guard let self, !Task.isCancelled, let buffer else { return }
                self.pixelBuffers[id] = buffer
                self.refresh()
            })
        }
    }

    // MARK: Helpers

    private func window(at global: CGPoint) -> WindowInfo? {
        windows.first { $0.frame.contains(global) }
    }

    private func clamped(_ point: CGPoint, in view: OverlayView) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), view.bounds.width), y: min(max(point.y, 0), view.bounds.height))
    }

    private func snapped(_ point: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }

    // MARK: Rendering

    private func refresh() {
        for view in views {
            view.render(renderState(for: view))
        }
    }

    private func renderState(for view: OverlayView) -> OverlayRenderState {
        var state = OverlayRenderState()
        state.mode = mode
        state.isActive = view === activeView
        state.dimsScreen = mode == .area || mode == .window

        if mode == .window, let hoveredWindow {
            let local = view.localRect(fromGlobal: hoveredWindow.frame)
            if local.intersects(view.bounds) {
                state.highlight = local
                if state.isActive {
                    let title = hoveredWindow.title.isEmpty ? hoveredWindow.owner : "\(hoveredWindow.owner): \(hoveredWindow.title)"
                    state.label = title
                    state.labelAnchor = local.intersection(view.bounds)
                }
            }
        }

        guard state.isActive else { return state }
        let scale = view.snapshot.scale
        state.pointer = pointer

        switch mode {
        case .area:
            state.selection = selection
            state.showsCrosshair = !isDragging
            if let selection {
                state.label = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
                state.labelAnchor = selection
            }
            if intent == .record {
                state.hint = isDragging
                    ? "Space: move   Shift: square   Option: from center"
                    : "Drag the area to record   Click: window   Return: full screen   Esc: cancel"
            } else {
                state.hint = isDragging
                    ? "Space: move   Shift: square   Option: from center" + (intent == .capture ? "   Control: copy only" : "")
                    : "Drag to select   Click: window   Space: window mode   Return: full screen   Tab: copy color   Esc: cancel"
            }
        case .window:
            state.hint = intent == .record
                ? "Click the window to record   Space: area mode   Return: full screen   Esc: cancel"
                : "Click a window   Space: area mode   Return: full screen   Esc: cancel"
        case .picker:
            state.hint = "Click: copy color   Shift-click: compare contrast   Arrows: nudge   Esc: cancel"
        case .ruler:
            if let span = rulerSpan(in: view), !isDragging || selection == nil {
                let y = pointer.y
                let x = pointer.x
                let minX = CGFloat(span.minX) / scale
                let maxX = CGFloat(span.maxX + 1) / scale
                let minY = CGFloat(span.minY) / scale
                let maxY = CGFloat(span.maxY + 1) / scale
                var parts: [String] = []
                if rulerAxis != .vertical {
                    state.rulerLines.append((CGPoint(x: minX, y: y), CGPoint(x: maxX, y: y)))
                    parts.append("\(Int((maxX - minX).rounded()))")
                }
                if rulerAxis != .horizontal {
                    state.rulerLines.append((CGPoint(x: x, y: minY), CGPoint(x: x, y: maxY)))
                    parts.append("\(Int((maxY - minY).rounded()))")
                }
                state.label = parts.joined(separator: " × ") + " " + unit(for: scale)
                state.labelAnchor = CGRect(x: x + 8, y: y + 8, width: 1, height: 1)
            }
            if let selection {
                state.rulerBox = selection
                state.label = measurementText(width: selection.width, height: selection.height, scale: scale)
                state.labelAnchor = selection
            }
            let axis = rulerAxis == .both ? "" : (rulerAxis == .vertical ? "   Vertical only" : "   Horizontal only")
            state.hint = pixelBuffers[view.snapshot.displayID] == nil
                ? "Preparing ruler…"
                : "Drag to measure   Click or ⌘C: copy   Scroll: sensitivity \(rulerTolerance)   Arrows: axis\(axis)   Esc: done"
        }

        let showsLoupe = mode == .picker || mode == .ruler || (settings.showMagnifier && (mode == .area))
        if showsLoupe {
            let (px, py) = pixel(of: pointer, in: view)
            let color = color(at: pointer, in: view)
            var contrast: String?
            if let referenceColor, let color {
                contrast = String(format: "Contrast %.2f:1", RGBAColor.contrastRatio(referenceColor, color))
            }
            state.loupe = LoupeState(
                pixelX: px, pixelY: py,
                pointLabel: "\(Int(pointer.x.rounded())), \(Int(pointer.y.rounded()))",
                color: color,
                colorText: color?.string(in: settings.colorFormat) ?? "",
                contrast: contrast,
                large: mode == .picker
            )
        }
        return state
    }
}
