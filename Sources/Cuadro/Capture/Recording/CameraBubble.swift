import AVFoundation
import AppKit
import CuadroKit
import QuartzCore

/// The cameras a recording can show in its bubble.
nonisolated enum CameraDevices {
    static func available() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
    }

    /// The camera with `uniqueID`, else the one macOS prefers, else any.
    static func device(for uniqueID: String?) -> AVCaptureDevice? {
        if let uniqueID, let device = AVCaptureDevice(uniqueID: uniqueID) { return device }
        return AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video)
    }
}

enum CameraError: LocalizedError {
    case noCamera
    case unusable(String)

    var errorDescription: String? {
        switch self {
        case .noCamera: "No camera is connected."
        case .unusable(let name): "\(name) cannot be used right now."
        }
    }
}

/// Runs the camera behind the bubble's preview. AVCaptureSession blocks while it starts and stops,
/// so that happens on a queue of its own.
nonisolated final class CameraFeed: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "io.github.mrcat71.cuadro.camera", qos: .userInitiated)

    /// Shows the camera with `deviceID` (nil: the one macOS prefers) from now on, starting the
    /// session if it is not running yet.
    func show(deviceID: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try configure(deviceID: deviceID)
                    if !session.isRunning { session.startRunning() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            session.commitConfiguration()
        }
    }

    private func configure(deviceID: String?) throws {
        guard let device = CameraDevices.device(for: deviceID) else { throw CameraError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let previous = session.inputs
        for old in previous { session.removeInput(old) }
        guard session.canAddInput(input) else {
            for old in previous where session.canAddInput(old) { session.addInput(old) }
            throw CameraError.unusable(device.localizedName)
        }
        session.addInput(input)
        Log.capture.notice("Camera bubble shows \(device.localizedName, privacy: .public)")
    }
}

/// The camera bubble's window. A press anywhere drags the bubble; AppKit runs the drag, as for
/// the recording controls, since this panel is never the key window.
final class CameraBubblePanel: FloatingPanel {
    var onDrag: ((RecordingControlsDrag) -> Void)?

    init() {
        super.init(level: .recordingControls)
        hasShadow = true
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown, let onDrag else {
            super.sendEvent(event)
            return
        }
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

/// The camera's picture filled into a circle with a light ring; a person symbol until the first
/// frame, and in place of the camera for the UI self-check.
final class CameraBubbleView: NSView {
    let preview: AVCaptureVideoPreviewLayer?
    private let clip = CALayer()
    private let placeholder = CALayer()
    private var trackingArea: NSTrackingArea?

    private static let placeholderImage = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 96, weight: .regular).applying(.init(paletteColors: [NSColor(white: 1, alpha: 0.5)])))

    init(session: AVCaptureSession?) {
        preview = session.map { AVCaptureVideoPreviewLayer(session: $0) }
        super.init(frame: .zero)
        wantsLayer = true
        clip.masksToBounds = true
        clip.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
        // A layer's border draws above its sublayers, so the ring stays on top of the picture.
        clip.borderColor = NSColor(white: 1, alpha: 0.9).cgColor
        clip.borderWidth = 3
        placeholder.contents = Self.placeholderImage
        placeholder.contentsGravity = .resizeAspect
        clip.addSublayer(placeholder)
        if let preview {
            preview.videoGravity = .resizeAspectFill
            clip.addSublayer(preview)
        }
        layer?.addSublayer(clip)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Camera")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        clip.frame = bounds
        clip.cornerRadius = min(bounds.width, bounds.height) / 2
        preview?.frame = clip.bounds
        let side = (min(bounds.width, bounds.height) * 0.45).rounded()
        placeholder.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    }

    /// Mirrored, the bubble works like a mirror; the movie shows it the same way.
    func applyMirroring(_ mirrored: Bool) {
        guard let connection = preview?.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let tracking = NSTrackingArea(rect: bounds, options: [.activeAlways, .cursorUpdate, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        trackingArea = tracking
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The camera bubble of one Record Screen: a round window over the recording area. Recordings
/// leave Cuadro's windows out but let this one in, so the movie shows the bubble where it is on
/// the screen. Drag it to move it within the area; it keeps its place when the area moves or
/// changes size, see `CameraBubbleLayout`.
final class CameraBubble {
    let panel = CameraBubblePanel()
    /// The anchor a drag left the bubble at.
    var onMove: ((CGPoint) -> Void)?

    private let feed: CameraFeed?
    private let view: CameraBubbleView
    private var mirrored: Bool
    /// Where the bubble is now: the area in display-local y-down points, its display, the
    /// bubble's diameter and anchor.
    private var placement: (area: CGRect, display: RecordingDisplay, diameter: CGFloat, anchor: CGPoint)?
    /// Pointer and bubble frame, Cocoa global, when a drag began.
    private var dragStart: (pointer: CGPoint, frame: CGRect)?

    /// - Parameter placeholder: a person symbol in place of the camera, for the UI self-check.
    init(mirrored: Bool, placeholder: Bool = false) {
        self.mirrored = mirrored
        feed = placeholder ? nil : CameraFeed()
        view = CameraBubbleView(session: feed?.session)
        panel.contentView = view
        panel.onDrag = { [weak self] event in self?.drag(event) }
    }

    /// The bubble is on the screen: the area has room for it.
    var isShown: Bool { placement != nil && panel.isVisible }

    /// Starts the camera with `deviceID` (nil: the one macOS prefers), also to switch cameras.
    func start(deviceID: String?) async throws {
        guard let feed else { return }
        try await feed.show(deviceID: deviceID)
        view.applyMirroring(mirrored)
    }

    func setMirrored(_ mirrored: Bool) {
        self.mirrored = mirrored
        view.applyMirroring(mirrored)
    }

    /// Puts the bubble at `anchor` in `area` (display-local y-down points of `display`), as large
    /// as the area has room for; without room it hides.
    func place(in area: CGRect, on display: RecordingDisplay, anchor: CGPoint) {
        guard let diameter = CameraBubbleLayout.diameter(in: area.size) else {
            placement = nil
            panel.orderOut(nil)
            return
        }
        placement = (area, display, diameter, anchor)
        let frame = CameraBubbleLayout.frame(anchor: anchor, diameter: diameter, in: area)
        let resized = panel.frame.size != frame.size
        panel.setFrame(display.globalRect(frame), display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
            panel.invalidateShadow()
        } else if resized {
            panel.invalidateShadow()
        }
    }

    /// Hides the bubble and turns the camera off.
    func remove() {
        panel.orderOut(nil)
        feed?.stop()
        placement = nil
    }

    private func drag(_ event: RecordingControlsDrag) {
        guard let placement else { return }
        let pointer = NSEvent.mouseLocation
        switch event {
        case .began:
            dragStart = (pointer, panel.frame)
        case .moved:
            guard let start = dragStart else { return }
            let wanted = start.frame.offsetBy(dx: pointer.x - start.pointer.x, dy: pointer.y - start.pointer.y)
            let local = ScreenCoordinates.localTopLeft(fromCocoa: wanted, screenFrame: placement.display.frame)
            let anchor = CameraBubbleLayout.anchor(origin: local.origin, diameter: placement.diameter, in: placement.area)
            self.placement?.anchor = anchor
            let frame = CameraBubbleLayout.frame(anchor: anchor, diameter: placement.diameter, in: placement.area)
            panel.setFrameOrigin(placement.display.globalRect(frame).origin)
        case .ended:
            dragStart = nil
            onMove?(placement.anchor)
        }
    }
}
