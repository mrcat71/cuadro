import AppKit
import Carbon.HIToolbox
import CuadroKit
import QuartzCore
import SwiftUI

// MARK: Controls

@Observable
final class RecordingControlsModel {
    enum Phase {
        case adjusting, starting, recording, stopping
    }

    var phase = Phase.adjusting
    var elapsed: TimeInterval = 0
    /// The area in points, for the size label while adjusting.
    var size = CGSize.zero
    var microphone = false
    /// Where the buttons are, in the controls' y-down points: a press anywhere else drags.
    @ObservationIgnored var buttonFrames: [String: CGRect] = [:]

    func isOverButton(_ point: CGPoint) -> Bool {
        buttonFrames.values.contains { $0.contains(point) }
    }
}

enum RecordingControlsDrag {
    case began, moved, ended
}

/// The panel of the recording controls. A press anywhere but on a button drags the recording
/// frame along. AppKit runs the drag rather than a SwiftUI gesture: this panel is never the key
/// window, and the first click into such a window is not reliably a gesture's.
final class RecordingControlsPanel: FloatingPanel {
    var isOverButton: (CGPoint) -> Bool = { _ in false }
    var onDrag: ((RecordingControlsDrag) -> Void)?

    init() {
        super.init(level: .recordingControls)
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown, let onDrag, let contentView else {
            super.sendEvent(event)
            return
        }
        var point = contentView.convert(event.locationInWindow, from: nil)
        if !contentView.isFlipped { point.y = contentView.bounds.height - point.y }
        guard !isOverButton(point) else {
            super.sendEvent(event)
            return
        }
        // The recording may end mid-drag and retire this panel; it lives until the drag ends.
        withExtendedLifetime(self) {
            NSCursor.closedHand.push()
            onDrag(.began)
            while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
                onDrag(.moved)
            }
            onDrag(.ended)
            NSCursor.pop()
        }
    }
}

/// The bar below the recording frame: size, microphone, Cancel and Record while the frame is
/// adjusted, then the timer and Stop. Dragging the bar moves the frame, also while recording;
/// `RecordingControlsPanel` runs that drag.
struct RecordingControlsView: View {
    let model: RecordingControlsModel
    var record: () -> Void = {}
    var cancel: () -> Void = {}
    var stop: () -> Void = {}
    var toggleMicrophone: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            switch model.phase {
            case .adjusting, .starting: adjustingControls
            case .recording, .stopping: recordingControls
            }
        }
        // The bar's panel never becomes the key window, which would draw its buttons dimmed.
        .environment(\.controlActiveState, .key)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .help("Drag to move the area")
        .padding(10)
    }

    @ViewBuilder private var adjustingControls: some View {
        let width = Int(model.size.width.rounded())
        let height = Int(model.size.height.rounded())
        Text("\(width) × \(height)")
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityLabel("Area \(width) by \(height) points")
        Button(action: toggleMicrophone) {
            Image(systemName: model.microphone ? "mic.fill" : "mic.slash")
                .frame(width: 16)
        }
        .buttonStyle(.glass)
        .help(model.microphone ? "Records the microphone. Click to leave it out." : "Leaves the microphone out. Click to record it.")
        .accessibilityLabel(model.microphone ? "Microphone on" : "Microphone off")
        .reportsButtonFrame("microphone", to: model)
        Button("Cancel", action: cancel)
            .buttonStyle(.glass)
            .reportsButtonFrame("cancel", to: model)
        Button(action: record) {
            Label("Record", systemImage: "record.circle")
        }
        .buttonStyle(RecordingActionStyle())
        .disabled(model.phase == .starting)
        .reportsButtonFrame("record", to: model)
    }

    @ViewBuilder private var recordingControls: some View {
        Circle()
            .fill(.red)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
        Text(Self.format(model.elapsed))
            .font(.system(size: 14, weight: .semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
            .accessibilityLabel("Recording, \(Int(model.elapsed)) seconds")
        if model.microphone {
            Image(systemName: "mic.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("With the microphone")
        }
        Button(action: stop) {
            Label("Stop", systemImage: "stop.fill")
        }
        .buttonStyle(RecordingActionStyle())
        .disabled(model.phase == .stopping)
        .reportsButtonFrame("stop", to: model)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private extension View {
    /// Keeps the controls panel from dragging when a press lands on this button.
    func reportsButtonFrame(_ name: String, to model: RecordingControlsModel) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            model.buttonFrames[name] = frame
        }
    }
}

/// Record and Stop: solid red. A prominent button would turn gray, since the controls' panel
/// never becomes the key window.
struct RecordingActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.red.opacity(configuration.isPressed ? 0.7 : 1)))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// The red border around the area while it records; clicks pass through it.
struct RecordingBorderView: View {
    let size: CGSize

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Color.red, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .frame(width: size.width + 8, height: size.height + 8)
    }
}

// MARK: Adjusting

/// Covers the recording's display while the frame is adjusted: dims everything outside the
/// frame and takes the pointer and the keyboard there.
final class RecordingShieldWindow: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        // The clear inside of the frame takes clicks too: dragging there moves the frame.
        ignoresMouseEvents = false
        animationBehavior = .none
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Adjusts the recording frame, in display-local y-down points: drag inside to move it, drag a
/// handle to resize it, drag outside to draw a new one. Return records, Esc cancels, arrows nudge.
final class RecordingShieldView: NSView {
    var area: CGRect {
        didSet { shapes.render(area: area) }
    }

    var onChange: ((CGRect) -> Void)?
    var onRecord: (() -> Void)?
    var onCancel: (() -> Void)?

    private enum Drag {
        case move(from: CGPoint, area: CGRect)
        case resize(RectHandle)
        case draw(from: CGPoint)
    }

    private static let handleRadius: CGFloat = 9
    private static let hintText = "Drag to move   Handles: resize   Drag outside: new area   Return: record   Esc: cancel"

    private let scale: CGFloat
    private let shapes = RecordingShieldShapes()
    private let hint = NSHostingView(rootView: GlassLabel(text: RecordingShieldView.hintText, secondary: true))
    private var trackingArea: NSTrackingArea?
    private var drag: Drag?

    /// - Parameter hintTop: distance of the hint from the top, below the menu bar and any notch.
    init(size: CGSize, area: CGRect, scale: CGFloat, hintTop: CGFloat) {
        self.area = area
        self.scale = scale
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        shapes.frame = bounds
        shapes.autoresizingMask = [.width, .height]
        addSubview(shapes)
        let hintSize = hint.fittingSize
        hint.frame = CGRect(x: bounds.midX - hintSize.width / 2, y: hintTop, width: hintSize.width, height: hintSize.height)
        addSubview(hint)
        shapes.render(area: area)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let tracking = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .cursorUpdate, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        trackingArea = tracking
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: point(of: event)) }
    override func mouseMoved(with event: NSEvent) { updateCursor(at: point(of: event)) }

    override func mouseDown(with event: NSEvent) {
        let point = point(of: event)
        switch RecordingArea.hit(point, area: area, handleRadius: Self.handleRadius) {
        case .handle(let handle):
            drag = .resize(handle)
        case .inside:
            drag = .move(from: point, area: area)
            NSCursor.closedHand.set()
        case .outside:
            drag = .draw(from: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = point(of: event)
        switch drag {
        case .move(let from, let start):
            update(RecordingArea.moved(start, by: point - from, within: bounds, scale: scale))
        case .resize(let handle):
            update(RecordingArea.resized(area, handle: handle, to: point, within: bounds, scale: scale))
        case .draw(let from):
            // Until the new area reaches the minimum size, the old one stays.
            if let drawn = RecordingArea.drawn(from: from, to: point, within: bounds, scale: scale) {
                update(drawn)
            }
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        updateCursor(at: point(of: event))
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: onRecord?()
        case kVK_Escape: onCancel?()
        case kVK_LeftArrow: nudge(dx: -step, dy: 0)
        case kVK_RightArrow: nudge(dx: step, dy: 0)
        case kVK_UpArrow: nudge(dx: 0, dy: -step)
        case kVK_DownArrow: nudge(dx: 0, dy: step)
        default: super.keyDown(with: event)
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        update(RecordingArea.moved(area, by: CGPoint(x: dx, y: dy), within: bounds, scale: scale))
    }

    private func update(_ rect: CGRect) {
        guard rect != area else { return }
        area = rect
        onChange?(rect)
    }

    private func updateCursor(at point: CGPoint) {
        guard drag == nil else { return }
        switch RecordingArea.hit(point, area: area, handleRadius: Self.handleRadius) {
        case .handle(let handle): NSCursor.frameResize(position: handle.cursorPosition, directions: .all).set()
        case .inside: NSCursor.openHand.set()
        case .outside: NSCursor.crosshair.set()
        }
    }

    private func point(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }
}

private extension RectHandle {
    var cursorPosition: NSCursor.FrameResizePosition {
        switch self {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        }
    }
}

/// GPU-composited dimming, frame and handles of the adjust stage.
final class RecordingShieldShapes: NSView {
    private let root = CALayer()
    private let dim = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let border = CAShapeLayer()
    private let handles = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = root
        wantsLayer = true
        let noAnimations: [String: CAAction] = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        for shape in [dim, outline, border, handles] {
            shape.actions = noAnimations
            shape.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            root.addSublayer(shape)
        }
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        outline.strokeColor = NSColor.black.withAlphaComponent(0.35).cgColor
        outline.lineWidth = 3
        outline.fillColor = nil
        border.strokeColor = NSColor.white.cgColor
        border.lineWidth = 1
        border.fillColor = nil
        handles.fillColor = NSColor.white.cgColor
        handles.strokeColor = NSColor.black.withAlphaComponent(0.45).cgColor
        handles.lineWidth = 1
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        for shape in root.sublayers ?? [] { shape.frame = bounds }
    }

    /// `area` is in y-down points; the paths are flipped into the layer's y-up space.
    func render(area: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for shape in root.sublayers ?? [] where shape.frame != bounds { shape.frame = bounds }
        var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
        let dimPath = CGMutablePath()
        dimPath.addRect(bounds, transform: flip)
        dimPath.addRect(area, transform: flip)
        dim.path = dimPath
        let frame = CGPath(rect: area.insetBy(dx: -0.5, dy: -0.5), transform: &flip)
        outline.path = frame
        border.path = frame
        let dots = CGMutablePath()
        for handle in RectHandle.allCases {
            let point = handle.point(in: area)
            dots.addEllipse(in: CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9), transform: flip)
        }
        handles.path = dots
    }
}
