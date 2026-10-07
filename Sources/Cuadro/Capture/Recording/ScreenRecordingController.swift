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
/// controls moves the frame and pans the movie, also onto another display, and the movie saved
/// to the screenshots folder.
final class ScreenRecordingController {
    /// The display the frame is on.
    private var display: RecordingDisplay
    /// Every display the frame can move to, the one it started on first.
    private let displays: [RecordingDisplay]
    /// Display-local y-down points, on the pixel grid.
    private(set) var area: CGRect
    private let returnFocus: () -> Void
    private let completion: () -> Void
    private let model = RecordingControlsModel()
    private var session: RecordingSession?
    /// The movie's pixels, and the pixels per point of the display it started on.
    private var movieSize = CGSize.zero
    private var movieScale: CGFloat = 1
    /// What ScreenCaptureKit can record, from the start of the recording: the displays and
    /// Cuadro's own app, which every stream leaves out.
    private var shareable: (displays: [SCDisplay], excluded: [SCRunningApplication])?
    private var shield: RecordingShieldWindow?
    private var shieldView: RecordingShieldView?
    private var borderPanel: FloatingPanel?
    private var controlsPanel: RecordingControlsPanel?
    private var timer: Timer?
    private var startDate = Date()
    /// Pointer, area and controls origin, all Cocoa global, when a drag of the controls began.
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
        displays = [display] + NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID, id != display.displayID else { return nil }
            return RecordingDisplay(displayID: id, frame: screen.frame, scale: screen.backingScaleFactor)
        }
        self.area = RecordingArea.moved(area, by: .zero, within: display.bounds, scale: display.scale)
        self.returnFocus = returnFocus
        self.completion = completion
        model.microphone = microphone
        model.size = self.area.size
    }

    /// Shows the frame for adjusting. Record, Return or the Record Screen shortcut start the
    /// recording; Cancel, Esc or a right-click drop it.
    func begin() {
        showShield()
        showControls()
    }

    /// Dims the frame's display and takes the pointer and the keyboard there, in place of the
    /// shield of a display the frame left.
    private func showShield() {
        retire([shield])
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
        let ownPID = ProcessInfo.processInfo.processIdentifier
        shareable = (content.displays, content.applications.filter { $0.processID == ownPID })
        guard let source = source(for: display) else { throw CaptureError.noDisplays }
        let pixels = RecordingArea.pixelSize(of: area, scale: display.scale)
        movieSize = CGSize(width: pixels.width, height: pixels.height)
        movieScale = display.scale
        let directory = ImageExporter.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try RecordingSession(
            source: source,
            crop: crop(of: area, on: display),
            options: options,
            outputURL: directory.appendingPathComponent("Recording.mp4")
        )
    }

    /// The stream source for `display`: all of it but Cuadro's own windows.
    private func source(for display: RecordingDisplay) -> RecordingSource? {
        guard let shareable, let screen = shareable.displays.first(where: { $0.displayID == display.displayID }) else { return nil }
        let filter = SCContentFilter(display: screen, excludingApplications: shareable.excluded, exceptingWindows: [])
        return RecordingSource(displayID: display.displayID, filter: filter, frameSize: display.pixelSize)
    }

    /// The crop for `area` in the frame pixels of `display`.
    private func crop(of area: CGRect, on display: RecordingDisplay) -> CGRect {
        RecordingArea.crop(of: area, scale: display.scale, movieSize: movieSize, movieScale: movieScale, frameSize: display.pixelSize)
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
            controlsDrag = (pointer, display.globalRect(area), panel.frame.origin)
        case .moved:
            guard let drag = controlsDrag else { return }
            // Cocoa global points: once its center is over another display, the area moves there.
            let wanted = drag.area.offsetBy(dx: pointer.x - drag.pointer.x, dy: pointer.y - drag.pointer.y)
            let candidates = movableDisplays
            let current = candidates.firstIndex { $0.displayID == display.displayID } ?? 0
            let target = candidates[RecordingArea.displayIndex(for: wanted, among: candidates.map(\.frame), current: current)]
            let local = ScreenCoordinates.localTopLeft(fromCocoa: wanted, screenFrame: target.frame)
            let moved = RecordingArea.moved(local, by: .zero, within: target.bounds, scale: target.scale)
            move(to: moved, on: target)
            // The controls follow the area, stopping with it at the display's edges.
            let shift = target.globalRect(moved).origin - drag.area.origin
            panel.setFrameOrigin(onScreen(drag.controls + shift, size: panel.frame.size))
        case .ended:
            controlsDrag = nil
        }
    }

    /// The displays the area can move to now: while recording, those ScreenCaptureKit records.
    private var movableDisplays: [RecordingDisplay] {
        guard phase == .recording, let shareable else { return displays }
        return displays.filter { candidate in
            candidate.displayID == display.displayID || shareable.displays.contains { $0.displayID == candidate.displayID }
        }
    }

    private func move(to newArea: CGRect, on target: RecordingDisplay) {
        let changesDisplay = target.displayID != display.displayID
        guard newArea != area || changesDisplay else { return }
        area = newArea
        display = target
        switch phase {
        case .adjusting, .starting:
            if changesDisplay {
                showShield()
            } else {
                shieldView?.area = newArea
            }
        case .recording:
            borderPanel?.setFrameOrigin(display.globalRect(newArea).insetBy(dx: -4, dy: -4).origin)
            let crop = crop(of: newArea, on: display)
            if !changesDisplay {
                session?.move(cropOrigin: crop.origin)
            } else if let source = source(for: display) {
                session?.move(to: source, crop: crop)
                Log.capture.notice("Recording moved to display \(self.display.displayID)")
            }
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
