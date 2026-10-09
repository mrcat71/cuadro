import AppKit
import CuadroKit
@preconcurrency import ScreenCaptureKit

/// Entry point for every capture mode and the shared post-capture pipeline.
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var overlay: OverlayController?
    private var scrollSession: ScrollCaptureController?
    private var recorder: ScreenRecordingController?
    /// Record Screen with Microphone started the selection on its way to `recorder`.
    private var recordsMicrophone = false
    private var isStarting = false
    private let settings = AppSettings.shared

    var isBusy: Bool { overlay != nil || scrollSession != nil || isStarting || recorder?.isAdjusting == true }
    /// A recording runs (not while its frame is still being adjusted).
    var isRecording: Bool { recorder?.isRecording == true }
    /// The recording frame is shown for adjusting, before the recording starts.
    var isAdjustingRecording: Bool { recorder?.isAdjusting == true }
    var recordingElapsed: TimeInterval? { isRecording ? recorder?.elapsed : nil }

    /// - Parameter copyOnly: Control was held (a Control variant of the shortcut, or a menu
    ///   click): the screenshot only goes to the clipboard, nothing opens.
    func perform(_ action: AppAction, copyOnly: Bool = false) {
        switch action {
        case .captureArea: beginOverlay(mode: .area, intent: .capture, copyOnly: copyOnly)
        case .captureWindow: beginOverlay(mode: .window, intent: .capture, copyOnly: copyOnly)
        case .captureActiveWindow: captureActiveWindow(copyOnly: copyOnly)
        case .captureFullscreen: captureFullscreen(copyOnly: copyOnly)
        case .captureScrolling: beginOverlay(mode: .area, intent: .scrolling)
        case .repeatArea: repeatLastArea(copyOnly: copyOnly)
        case .captureDelayed: captureDelayed(seconds: settings.delaySeconds, copyOnly: copyOnly)
        case .recognizeText: beginOverlay(mode: .area, intent: .recognizeText)
        case .pickColor: beginOverlay(mode: .picker, intent: .capture)
        case .measure: beginOverlay(mode: .ruler, intent: .capture)
        case .openFile: DocumentOpener.openFile()
        case .openClipboard: DocumentOpener.openClipboard()
        case .recordScreen: toggleRecording(microphone: false)
        case .recordScreenWithMicrophone: toggleRecording(microphone: true)
        }
    }

    /// Starts picking the area to record; with a recording under way, starts it once its frame
    /// is adjusted or stops it.
    func toggleRecording(microphone: Bool = false) {
        if let recorder {
            recorder.primaryAction()
            return
        }
        guard !isBusy, ensurePermission() else { return }
        guard microphone else {
            recordsMicrophone = false
            beginOverlay(mode: .area, intent: .record)
            return
        }
        // Ask before the overlay, which would cover the system prompt.
        isStarting = true
        Task {
            let allowed = await ScreenRecordingController.allowMicrophone(openingSettings: true)
            isStarting = false
            guard allowed else { return }
            recordsMicrophone = true
            beginOverlay(mode: .area, intent: .record)
        }
    }

    func pinArea() {
        beginOverlay(mode: .area, intent: .pin)
    }

    func captureDelayed(seconds: Int, copyOnly: Bool = false) {
        if CountdownHUD.shared.isRunning {
            CountdownHUD.shared.cancel()
            return
        }
        guard !isBusy, ensurePermission() else { return }
        CountdownHUD.shared.start(seconds: seconds) { [weak self] in
            self?.beginOverlay(mode: .area, intent: .capture, copyOnly: copyOnly)
        }
    }

    /// Shows the permissions window instead of capturing until Screen Recording works, including
    /// after a fresh grant that still needs a relaunch.
    private func ensurePermission() -> Bool {
        let permissions = PermissionCenter.shared
        if permissions.canCapture { return true }
        if permissions.screenRecordingState == .missing {
            permissions.requestScreenRecording()
        }
        OnboardingWindowController.shared.show()
        return false
    }

    // MARK: Modes

    func beginOverlay(mode: OverlayMode, intent: CaptureIntent, copyOnly: Bool = false) {
        guard !isBusy, ensurePermission() else { return }
        isStarting = true
        let started = ContinuousClock.now
        let frontmost = NSWorkspace.shared.frontmostApplication
        let windows = WindowList.onScreenWindows()
        // Selections answer the shortcut right away; picker and ruler do not dim the screen.
        let curtain = mode == .area || mode == .window ? CaptureCurtain() : nil
        Task { [weak self] in
            guard let self else {
                curtain?.remove()
                return
            }
            do {
                let snapshots = try await ScreenCaptureService.shared.snapshotAllDisplays(showCursor: settings.showCursor, waitingFor: curtain?.windows ?? [])
                let captured = ContinuousClock.now - started
                let controller = OverlayController(snapshots: snapshots, windows: windows, mode: mode, intent: intent) { [weak self] outcome in
                    self?.overlay = nil
                    // The overlay finishes from the mouse-up or Return event, so this is the
                    // Control key at the moment the selection was made.
                    let control = NSEvent.modifierFlags.contains(.control)
                    self?.handle(outcome, intent: intent, frontmost: frontmost, copyOnly: copyOnly || control)
                }
                overlay = controller
                isStarting = false
                controller.begin()
                curtain?.remove()
                let ready = ContinuousClock.now - started
                Log.capture.notice("Overlay ready in \(ready.milliseconds, format: .fixed(precision: 0)) ms, \(snapshots.count) displays captured in \(captured.milliseconds, format: .fixed(precision: 0)) ms")
            } catch {
                curtain?.remove()
                isStarting = false
                ToastCenter.shared.showError("Capture failed", error)
            }
        }
    }

    func captureFullscreen(copyOnly: Bool = false) {
        guard !isBusy, ensurePermission(), let displayID = NSScreen.withMouse?.displayID else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        isStarting = true
        let started = ContinuousClock.now
        Task {
            defer { isStarting = false }
            do {
                let snapshot = try await ScreenCaptureService.shared.snapshotDisplay(displayID, showCursor: settings.showCursor)
                let captured = ContinuousClock.now - started
                Log.capture.notice("Full screen captured in \(captured.milliseconds, format: .fixed(precision: 0)) ms")
                deliver(CaptureResult(image: snapshot.image, scale: snapshot.scale, kind: .fullscreen, screenRect: snapshot.frame, appName: frontmost?.localizedName), frontmost: frontmost, copyOnly: copyOnly)
            } catch {
                ToastCenter.shared.showError("Capture failed", error)
            }
        }
    }

    func captureActiveWindow(copyOnly: Bool = false) {
        guard !isBusy, ensurePermission() else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard let pid = frontmost?.processIdentifier,
              let target = WindowList.onScreenWindows().first(where: { $0.pid == pid && $0.layer == 0 })
        else {
            beginOverlay(mode: .window, intent: .capture, copyOnly: copyOnly)
            return
        }
        captureWindow(target, frontmost: frontmost, copyOnly: copyOnly)
    }

    private func captureWindow(_ target: WindowInfo, frontmost: NSRunningApplication?, copyOnly: Bool) {
        isStarting = true
        Task {
            defer { isStarting = false }
            do {
                let captured = try await ScreenCaptureService.shared.captureWindow(target.id, includeShadow: settings.windowShadow)
                deliver(CaptureResult(image: captured.image, scale: captured.scale, kind: .window, screenRect: target.frame, appName: target.owner), frontmost: frontmost, copyOnly: copyOnly)
            } catch {
                ToastCenter.shared.showError("Window capture failed", error)
                restoreFocus(frontmost)
            }
        }
    }

    func repeatLastArea(copyOnly: Bool = false) {
        guard let area = settings.lastArea,
              let screen = NSScreen.screen(for: area.displayID) ?? NSScreen.screens.first(where: { $0.frame.intersects(area.rect) }),
              let displayID = screen.displayID
        else {
            beginOverlay(mode: .area, intent: .capture, copyOnly: copyOnly)
            return
        }
        guard !isBusy, ensurePermission() else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        isStarting = true
        Task {
            defer { isStarting = false }
            do {
                let snapshot = try await ScreenCaptureService.shared.snapshotDisplay(displayID, showCursor: settings.showCursor)
                let local = ScreenCoordinates.localTopLeft(fromCocoa: area.rect, screenFrame: snapshot.frame)
                guard let image = snapshot.crop(local) else { throw CaptureError.emptySelection }
                deliver(CaptureResult(image: image, scale: snapshot.scale, kind: .area, screenRect: area.rect, appName: frontmost?.localizedName), frontmost: frontmost, copyOnly: copyOnly)
            } catch {
                ToastCenter.shared.showError("Capture failed", error)
            }
        }
    }

    // MARK: Outcomes

    private func handle(_ outcome: OverlayOutcome, intent: CaptureIntent, frontmost: NSRunningApplication?, copyOnly: Bool) {
        switch outcome {
        case .cancelled, .finished:
            restoreFocus(frontmost)
        case .display(let snapshot) where intent == .record:
            beginRecording(display: snapshot, region: CGRect(origin: .zero, size: snapshot.frame.size), frontmost: frontmost)
        case .display(let snapshot):
            deliver(CaptureResult(image: snapshot.image, scale: snapshot.scale, kind: .fullscreen, screenRect: snapshot.frame, appName: frontmost?.localizedName), frontmost: frontmost, copyOnly: copyOnly)
        case .window(let window):
            captureWindow(window, frontmost: frontmost, copyOnly: copyOnly)
        case .area(let snapshot, let rect):
            guard let image = snapshot.crop(rect) else {
                restoreFocus(frontmost)
                return
            }
            let screenRect = snapshot.globalRect(fromLocal: rect)
            switch intent {
            case .capture:
                settings.lastArea = StoredArea(rect: screenRect, displayID: snapshot.displayID)
                deliver(CaptureResult(image: image, scale: snapshot.scale, kind: .area, screenRect: screenRect, appName: frontmost?.localizedName), frontmost: frontmost, copyOnly: copyOnly)
            case .recognizeText:
                restoreFocus(frontmost)
                recognizeText(in: image)
            case .pin:
                restoreFocus(frontmost)
                PinWindowController.pin(image: image, scale: snapshot.scale, at: screenRect)
            case .scrolling:
                restoreFocus(frontmost)
                startScrolling(display: snapshot, region: rect)
            case .record:
                beginRecording(display: snapshot, region: rect, frontmost: frontmost)
            }
        }
    }

    private func startScrolling(display: DisplaySnapshot, region: CGRect) {
        let session = ScrollCaptureController(display: display, region: region) { [weak self] result in
            self?.scrollSession = nil
            if let result {
                self?.deliver(result, frontmost: nil)
            }
        }
        scrollSession = session
        session.start()
    }

    /// Shows `region` (display-local y-down points) of a display with the recording controls, to
    /// adjust before recording. Focus goes back to `frontmost` once the recording starts.
    private func beginRecording(display: DisplaySnapshot, region: CGRect, frontmost: NSRunningApplication?) {
        guard recorder == nil else { return }
        let controller = ScreenRecordingController(
            display: RecordingDisplay(display), area: region, microphone: recordsMicrophone,
            returnFocus: { [weak self] in self?.restoreFocus(frontmost) }
        ) { [weak self] in
            self?.recorder = nil
            NotificationCenter.default.post(name: .recordingChanged, object: nil)
        }
        recorder = controller
        controller.begin()
    }

    func recognizeText(in image: CGImage) {
        Task {
            do {
                let result = try await TextRecognizer.recognize(image)
                if let first = result.barcodes.first {
                    Pasteboard.copy(text: result.barcodes.joined(separator: "\n"))
                    let title = result.barcodes.count > 1 ? "\(result.barcodes.count) codes copied" : "Code copied"
                    ToastCenter.shared.show(title, detail: first, symbol: "qrcode")
                } else if !result.text.isEmpty {
                    Pasteboard.copy(text: result.text)
                    let firstLine = result.text.split(separator: "\n").first.map(String.init) ?? result.text
                    ToastCenter.shared.show("Text copied", detail: firstLine, symbol: "text.viewfinder")
                } else {
                    ToastCenter.shared.show("No text found", style: .warning, symbol: "text.viewfinder")
                }
            } catch {
                ToastCenter.shared.showError("Text recognition failed", error)
            }
        }
    }

    // MARK: Pipeline

    /// Sound, history, clipboard, auto-save, then editor / thumbnail / nothing.
    /// - Parameter copyOnly: only copy to the clipboard: no file, editor or thumbnail.
    func deliver(_ result: CaptureResult, frontmost: NSRunningApplication?, copyOnly: Bool = false) {
        ShutterSound.play()
        if copyOnly {
            restoreFocus(frontmost)
            Task {
                if await Pasteboard.copyInBackground(image: result.image, scale: result.scale) {
                    ToastCenter.shared.show("Copied to clipboard", detail: "\(result.image.width) × \(result.image.height) px")
                } else {
                    ToastCenter.shared.show("Could not copy the screenshot", style: .failure)
                }
                HistoryStore.shared.add(result.image, scale: result.scale)
            }
            return
        }
        // Show the result right away; encoding for the clipboard and disk happens off the main actor.
        let afterCapture = settings.afterCapture
        switch afterCapture {
        case .openEditor:
            EditorWindowController.open(result)
        case .showThumbnail:
            restoreFocus(frontmost)
            ThumbnailOverlay.shared.show(result)
        case .nothing:
            restoreFocus(frontmost)
        }
        let copy = settings.copyToClipboard
        let save = settings.autoSave
        Task {
            var notes: [String] = []
            if copy, await Pasteboard.copyInBackground(image: result.image, scale: result.scale) {
                notes.append("Copied")
            }
            if save {
                do {
                    let url = try await SaveService.quickSaveInBackground(result.image, scale: result.scale, appName: result.appName)
                    notes.append("Saved \(url.lastPathComponent)")
                } catch {
                    ToastCenter.shared.showError("Could not save", error)
                }
            }
            HistoryStore.shared.add(result.image, scale: result.scale)
            if afterCapture == .nothing {
                ToastCenter.shared.show(notes.isEmpty ? "Captured" : notes.joined(separator: ", "), detail: "\(result.image.width) × \(result.image.height) px")
            }
        }
    }

    /// Gives focus back to the app that was active before the overlay appeared.
    private func restoreFocus(_ app: NSRunningApplication?) {
        guard let app, !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }
}

/// Opening images from files and the clipboard.
enum DocumentOpener {
    static func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    static func open(_ url: URL) {
        guard let decoded = Pasteboard.decode(url: url) else {
            ToastCenter.shared.show("Cannot open \(url.lastPathComponent)", style: .failure)
            return
        }
        EditorWindowController.open(CaptureResult(
            image: decoded.image, scale: decoded.scale, kind: .file,
            title: url.deletingPathExtension().lastPathComponent
        ))
    }

    static func openClipboard() {
        guard let decoded = Pasteboard.image() else {
            ToastCenter.shared.show("No image on the clipboard", style: .warning, symbol: "doc.on.clipboard")
            return
        }
        EditorWindowController.open(CaptureResult(image: decoded.image, scale: decoded.scale, kind: .clipboard, title: "Clipboard Image"))
    }
}
