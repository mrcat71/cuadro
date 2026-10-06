import AppKit
import CuadroKit
@preconcurrency import ScreenCaptureKit

/// Entry point for every capture mode and the shared post-capture pipeline.
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var overlay: OverlayController?
    private var scrollSession: ScrollCaptureController?
    private var recorder: ScreenRecordingController?
    private var isStarting = false
    private let settings = AppSettings.shared

    var isBusy: Bool { overlay != nil || scrollSession != nil || isStarting }
    var isRecording: Bool { recorder != nil }
    var recordingElapsed: TimeInterval? { recorder?.elapsed }

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
        case .recordScreen: toggleRecording()
        }
    }

    /// Starts picking the area to record, or stops the recording in progress.
    func toggleRecording() {
        if let recorder {
            recorder.stop()
            return
        }
        beginOverlay(mode: .area, intent: .record)
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
        let frontmost = NSWorkspace.shared.frontmostApplication
        let windows = WindowList.onScreenWindows()
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshots = try await ScreenCaptureService.shared.snapshotAllDisplays(showCursor: settings.showCursor)
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
            } catch {
                isStarting = false
                ToastCenter.shared.showError("Capture failed", error)
            }
        }
    }

    func captureFullscreen(copyOnly: Bool = false) {
        guard !isBusy, ensurePermission(), let displayID = NSScreen.withMouse?.displayID else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        isStarting = true
        Task {
            defer { isStarting = false }
            do {
                let snapshot = try await ScreenCaptureService.shared.snapshotDisplay(displayID, showCursor: settings.showCursor)
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
            restoreFocus(frontmost)
            startRecording(display: snapshot, region: CGRect(origin: .zero, size: snapshot.frame.size))
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
                restoreFocus(frontmost)
                startRecording(display: snapshot, region: rect)
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

    /// Records `region` (display-local y-down points) of a display, without Cuadro's own windows.
    private func startRecording(display: DisplaySnapshot, region: CGRect) {
        guard recorder == nil else { return }
        isStarting = true
        Task { [weak self] in
            guard let self else { return }
            defer { isStarting = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let scDisplay = content.displays.first(where: { $0.displayID == display.displayID }) else {
                    throw CaptureError.noDisplays
                }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let filter = SCContentFilter(display: scDisplay, excludingApplications: content.applications.filter { $0.processID == ownPID }, exceptingWindows: [])
                let directory = ImageExporter.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let session = RecordingSession(
                    filter: filter,
                    configuration: .recording(region: region, scale: display.scale),
                    outputURL: directory.appendingPathComponent("Recording.mp4")
                )
                let controller = ScreenRecordingController(session: session, area: display.globalRect(fromLocal: region), screenFrame: display.frame) { [weak self] in
                    self?.recorder = nil
                    NotificationCenter.default.post(name: .recordingChanged, object: nil)
                }
                recorder = controller
                NotificationCenter.default.post(name: .recordingChanged, object: nil)
                do {
                    try await controller.start()
                } catch {
                    recorder = nil
                    NotificationCenter.default.post(name: .recordingChanged, object: nil)
                    throw error
                }
            } catch {
                ToastCenter.shared.showError("Could not start recording", error)
            }
        }
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
