import AVFoundation
import AppKit
import CuadroKit
@preconcurrency import ScreenCaptureKit

/// The display a recording happens on.
struct RecordingDisplay {
    let displayID: CGDirectDisplayID
    /// Cocoa global coordinates.
    let frame: CGRect
    /// Pixels per point.
    let scale: CGFloat

    init(displayID: CGDirectDisplayID, frame: CGRect, scale: CGFloat) {
        self.displayID = displayID
        self.frame = frame
        self.scale = scale
    }

    init(_ snapshot: DisplaySnapshot) {
        self.init(displayID: snapshot.displayID, frame: snapshot.frame, scale: snapshot.scale)
    }

    /// The display in its own y-down points: where the recording frame may go.
    var bounds: CGRect { CGRect(origin: .zero, size: frame.size) }

    /// Pixels of a whole-display frame.
    var pixelSize: CGSize { CGSize(width: (frame.width * scale).rounded(), height: (frame.height * scale).rounded()) }

    /// Cocoa global rect for a display-local y-down one.
    func globalRect(_ local: CGRect) -> CGRect {
        ScreenCoordinates.cocoaRect(fromLocalTopLeft: local, screenFrame: frame)
    }
}

/// One Record Screen: the frame shown for adjusting, the recording, during which dragging the
/// controls moves the frame and pans the movie, and the movie saved to the screenshots folder.
final class ScreenRecordingController {
    private let display: RecordingDisplay
    /// Display-local y-down points, on the pixel grid.
    private(set) var area: CGRect
    private let returnFocus: () -> Void
    private let completion: () -> Void
    private let model = RecordingControlsModel()
    private var session: RecordingSession?
    private var cropSize = CGSize.zero
    private var shield: RecordingShieldWindow?
    private var shieldView: RecordingShieldView?
    private var borderPanel: FloatingPanel?
    private var controlsPanel: RecordingControlsPanel?
    private var timer: Timer?
    private var startDate = Date()
    /// Pointer (Cocoa global), area and controls origin when a drag of the controls began.
    private var controlsDrag: (pointer: CGPoint, area: CGRect, controls: CGPoint)?
    private var isFinished = false

    var phase: RecordingControlsModel.Phase { model.phase }
    var isAdjusting: Bool { phase == .adjusting || phase == .starting }
    var isRecording: Bool { phase == .recording || phase == .stopping }
    var elapsed: TimeInterval { Date().timeIntervalSince(startDate) }

    /// - Parameters:
    ///   - area: display-local y-down points.
    ///   - microphone: starts with the microphone on (Record Screen with Microphone).
    ///   - returnFocus: gives focus back to the app that was active before the selection.
    ///   - completion: the controller is done: cancelled, failed or saved.
    init(display: RecordingDisplay, area: CGRect, microphone: Bool, returnFocus: @escaping () -> Void, completion: @escaping () -> Void) {
        self.display = display
        self.area = RecordingArea.moved(area, by: .zero, within: display.bounds, scale: display.scale)
        self.returnFocus = returnFocus
        self.completion = completion
        model.microphone = microphone
        model.size = self.area.size
    }

    /// Shows the frame for adjusting. Record, Return or the Record Screen shortcut start the
    /// recording; Cancel, Esc or a right-click drop it.
    func begin() {
        let shield = RecordingShieldWindow(frame: display.frame)
        let screen = NSScreen.screen(for: display.displayID)
        let hintTop = max(screen?.safeAreaInsets.top ?? 0, NSStatusBar.system.thickness) + 12
        let view = RecordingShieldView(size: display.frame.size, area: area, scale: display.scale, hintTop: hintTop)
        view.onChange = { [weak self] area in self?.adjusted(to: area) }
        view.onRecord = { [weak self] in self?.record() }
        view.onCancel = { [weak self] in self?.cancel() }
        shield.contentView = view
        shield.orderFrontRegardless()
        NSApp.activate()
        shield.makeKey()
        shield.makeFirstResponder(view)
        self.shield = shield
        shieldView = view
        showControls()
    }

    /// The Record Screen shortcut and menu item: start the adjusted recording or stop the running one.
    func primaryAction() {
        switch phase {
        case .adjusting: record()
        case .recording: stop()
        case .starting, .stopping: break
        }
    }

    func cancel() {
        guard phase == .adjusting else { return }
        returnFocus()
        finish()
    }

    func stop() {
        finishRecording(failure: nil)
    }

    // MARK: Adjusting

    private func adjusted(to newArea: CGRect) {
        // Once Record is pressed, the movie's crop is set.
        guard phase == .adjusting else {
            shieldView?.area = area
            return
        }
        area = newArea
        model.size = newArea.size
        placeControls()
    }

    private func toggleMicrophone() {
        guard phase == .adjusting else { return }
        if model.microphone {
            model.microphone = false
            return
        }
        // macOS asks in a window of its own, which the dimmed screen would cover.
        let asks = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        if asks { shield?.orderOut(nil) }
        Task {
            let allowed = await Self.allowMicrophone(openingSettings: false)
            guard phase == .adjusting else { return }
            model.microphone = allowed
            if asks, let shield {
                shield.orderFrontRegardless()
                NSApp.activate()
                shield.makeKey()
            }
        }
    }

    /// Asks for the microphone if macOS has not asked yet, and says how to turn it on when it
    /// stays off.
    static func allowMicrophone(openingSettings: Bool) async -> Bool {
        if await PermissionCenter.shared.requestMicrophone(openingSettings: openingSettings) { return true }
        ToastCenter.shared.show(
            "The microphone is off for Cuadro",
            detail: "Turn Cuadro on in System Settings > Privacy & Security > Microphone.",
            style: .warning, symbol: "mic.slash", duration: 5
        )
        return false
    }

    // MARK: Recording

    private func record() {
        guard phase == .adjusting else { return }
        model.phase = .starting
        // Access may have been withdrawn in System Settings since the microphone was switched on.
        model.microphone = model.microphone && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let options = RecordingOptions.current(microphone: model.microphone)
        Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await makeSession(options: options)
                session.onFailure = { [weak self] error in self?.finishRecording(failure: error) }
                self.session = session
                try await session.start()
                startDate = Date()
                model.elapsed = 0
                model.phase = .recording
                retire([shield])
                shield = nil
                shieldView = nil
                showBorder()
                showControls()
                let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.model.elapsed = self.elapsed
                    }
                }
                // Common modes keep the clock running while the controls are dragged.
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
                returnFocus()
                NotificationCenter.default.post(name: .recordingChanged, object: nil)
                Log.capture.notice("Recording started: \(Int(self.area.width)) × \(Int(self.area.height)) pt, microphone \(options.microphone ? "on" : "off", privacy: .public)")
            } catch {
                session = nil
                ToastCenter.shared.showError("Could not start recording", error)
                returnFocus()
                finish()
            }
        }
    }

    /// A stream of the whole display without Cuadro's own windows, cropped to the area.
    private func makeSession(options: RecordingOptions) async throws -> RecordingSession {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.displayID }) else {
            throw CaptureError.noDisplays
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(display: scDisplay, excludingApplications: content.applications.filter { $0.processID == ownPID }, exceptingWindows: [])
        let pixels = RecordingArea.pixelSize(of: area, scale: display.scale)
        cropSize = CGSize(width: pixels.width, height: pixels.height)
        let origin = RecordingArea.cropOrigin(of: area, scale: display.scale, cropSize: cropSize, frameSize: display.pixelSize)
        let directory = ImageExporter.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try RecordingSession(
            filter: filter,
            frameSize: display.pixelSize,
            crop: CGRect(origin: origin, size: cropSize),
            options: options,
            outputURL: directory.appendingPathComponent("Recording.mp4")
        )
    }

    /// Saves what was recorded, also after `failure` stopped the recording early.
    private func finishRecording(failure: Error?) {
        guard phase == .recording, let session else { return }
        model.phase = .stopping
        timer?.invalidate()
        let duration = elapsed
        removeChrome()
        Task {
            do {
                try await session.stop()
                let saved = try Self.save(session.outputURL)
                Pasteboard.copy(fileURL: saved)
                let frames = session.frameCounts
                Log.capture.notice("Recording saved: \(duration, format: .fixed(precision: 1)) s, \(frames.written) frames written, \(frames.dropped) dropped")
                if let failure {
                    ToastCenter.shared.show("Recording stopped early", detail: failure.localizedDescription, style: .warning, symbol: "film", duration: 5)
                } else {
                    ToastCenter.shared.show("Recording saved and copied", detail: saved.lastPathComponent, symbol: "film")
                }
                NSWorkspace.shared.activateFileViewerSelecting([saved])
            } catch {
                ToastCenter.shared.showError(failure == nil ? "Recording failed" : "Recording stopped", failure ?? error)
            }
            finish()
        }
    }

    /// Moves the finished movie into the screenshots folder under a unique name.
    private static func save(_ temporary: URL) throws -> URL {
        let folder = AppSettings.shared.saveFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = FileNameTemplate.render("Screen Recording {date} at {time}", context: .init())
        let url = FileNameTemplate.uniqueFileURL(directory: folder, baseName: name, pathExtension: "mp4") {
            FileManager.default.fileExists(atPath: $0.path)
        }
        try FileManager.default.moveItem(at: temporary, to: url)
        return url
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        timer?.invalidate()
        removeChrome()
        completion()
    }

    // MARK: Moving

    private func dragControls(_ event: RecordingControlsDrag) {
        guard phase == .adjusting || phase == .recording, let panel = controlsPanel else {
            controlsDrag = nil
            return
        }
        let pointer = NSEvent.mouseLocation
        switch event {
        case .began:
            controlsDrag = (pointer, area, panel.frame.origin)
        case .moved:
            guard let drag = controlsDrag else { return }
            let delta = CGPoint(x: pointer.x - drag.pointer.x, y: drag.pointer.y - pointer.y)
            let moved = RecordingArea.moved(drag.area, by: delta, within: display.bounds, scale: display.scale)
            // The controls follow the area, stopping with it at the display's edges.
            let origin = CGPoint(x: drag.controls.x + moved.minX - drag.area.minX, y: drag.controls.y - (moved.minY - drag.area.minY))
            panel.setFrameOrigin(onScreen(origin, size: panel.frame.size))
            move(to: moved)
        case .ended:
            controlsDrag = nil
        }
    }

    private func move(to newArea: CGRect) {
        guard newArea != area else { return }
        area = newArea
        switch phase {
        case .adjusting, .starting:
            shieldView?.area = newArea
        case .recording:
            borderPanel?.setFrameOrigin(display.globalRect(newArea).insetBy(dx: -4, dy: -4).origin)
            session?.move(cropOrigin: RecordingArea.cropOrigin(of: newArea, scale: display.scale, cropSize: cropSize, frameSize: display.pixelSize))
        case .stopping:
            break
        }
    }

    // MARK: Chrome

    private func showControls() {
        let panel = controlsPanel ?? RecordingControlsPanel()
        let model = model
        model.buttonFrames = [:]
        panel.isOverButton = { model.isOverButton($0) }
        panel.onDrag = { [weak self] event in self?.dragControls(event) }
        panel.host(RecordingControlsView(
            model: model,
            record: { [weak self] in self?.record() },
            cancel: { [weak self] in self?.cancel() },
            stop: { [weak self] in self?.stop() },
            toggleMicrophone: { [weak self] in self?.toggleMicrophone() }
        ))
        controlsPanel = panel
        placeControls()
        panel.orderFrontRegardless()
    }

    private func placeControls() {
        guard let panel = controlsPanel else { return }
        let origin = RecordingArea.controlsOrigin(for: display.globalRect(area), controlsSize: panel.frame.size, screen: display.frame)
        panel.setFrameOrigin(origin)
    }

    private func showBorder() {
        let border = FloatingPanel(level: .statusBar, clickThrough: true)
        border.host(RecordingBorderView(size: area.size))
        border.setFrame(display.globalRect(area).insetBy(dx: -4, dy: -4), display: false)
        border.orderFrontRegardless()
        borderPanel = border
    }

    private func onScreen(_ origin: CGPoint, size: CGSize) -> CGPoint {
        let screen = display.frame
        return CGPoint(
            x: min(max(origin.x, screen.minX), screen.maxX - size.width),
            y: min(max(origin.y, screen.minY), screen.maxY - size.height)
        )
    }

    private func removeChrome() {
        retire([shield, borderPanel, controlsPanel])
        shield = nil
        shieldView = nil
        borderPanel = nil
        controlsPanel = nil
    }

    /// Hides `windows` and releases them after the current event: a button or key in them may be
    /// what ended the recording.
    private func retire(_ windows: [NSWindow?]) {
        let closing = windows.compactMap { $0 }
        for window in closing {
            window.orderOut(nil)
        }
        Task { @MainActor in
            for window in closing { window.contentView = nil }
        }
    }

    // MARK: UI self-check

    /// `--ui-snapshot`: removes whatever this controller shows.
    func debugDismiss() {
        finish()
    }

    /// `--ui-snapshot`: the controls as they look while recording, without recording.
    func debugShowRecordingControls() {
        retire([shield])
        shield = nil
        shieldView = nil
        model.phase = .recording
        model.elapsed = 83
        showBorder()
        showControls()
    }
}
