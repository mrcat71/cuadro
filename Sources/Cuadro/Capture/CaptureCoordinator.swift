import AppKit
import CuadroKit

/// Entry point for every capture mode and the shared post-capture pipeline.
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var overlay: OverlayController?
    private var scrollSession: ScrollCaptureController?
    private var isStarting = false
    private let settings = AppSettings.shared

    var isBusy: Bool { overlay != nil || scrollSession != nil || isStarting }

    func perform(_ action: AppAction) {
        switch action {
        case .captureArea: beginOverlay(mode: .area, intent: .capture)
        case .captureWindow: beginOverlay(mode: .window, intent: .capture)
        case .captureActiveWindow: captureActiveWindow()
        case .captureFullscreen: captureFullscreen()
        case .captureScrolling: beginOverlay(mode: .area, intent: .scrolling)
        case .repeatArea: repeatLastArea()
        case .captureDelayed: captureDelayed(seconds: settings.delaySeconds)
        case .recognizeText: beginOverlay(mode: .area, intent: .recognizeText)
        case .pickColor: beginOverlay(mode: .picker, intent: .capture)
        case .measure: beginOverlay(mode: .ruler, intent: .capture)
        case .openFile: DocumentOpener.openFile()
        case .openClipboard: DocumentOpener.openClipboard()
        }
    }

    func pinArea() {
        beginOverlay(mode: .area, intent: .pin)
    }

    func captureDelayed(seconds: Int) {
        if CountdownHUD.shared.isRunning {
            CountdownHUD.shared.cancel()
            return
        }
        guard !isBusy, ensurePermission() else { return }
        CountdownHUD.shared.start(seconds: seconds) { [weak self] in
            self?.beginOverlay(mode: .area, intent: .capture)
        }
    }

    private func ensurePermission() -> Bool {
        if PermissionCenter.shared.hasScreenRecording { return true }
        PermissionCenter.shared.requestScreenRecording()
        OnboardingWindowController.shared.show()
        return false
    }

    // MARK: Modes

    func beginOverlay(mode: OverlayMode, intent: CaptureIntent) {
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
                    self?.handle(outcome, intent: intent, frontmost: frontmost)
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

    func captureFullscreen() {
        guard !isBusy, ensurePermission(), let displayID = NSScreen.withMouse?.displayID else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        isStarting = true
        Task {
            defer { isStarting = false }
            do {
                let snapshot = try await ScreenCaptureService.shared.snapshotDisplay(displayID, showCursor: settings.showCursor)
                deliver(CaptureResult(image: snapshot.image, scale: snapshot.scale, kind: .fullscreen, screenRect: snapshot.frame, appName: frontmost?.localizedName), frontmost: frontmost)
            } catch {
                ToastCenter.shared.showError("Capture failed", error)
            }
        }
    }

    func captureActiveWindow() {
        guard !isBusy, ensurePermission() else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard let pid = frontmost?.processIdentifier,
              let target = WindowList.onScreenWindows().first(where: { $0.pid == pid && $0.layer == 0 })
        else {
            beginOverlay(mode: .window, intent: .capture)
            return
        }
        captureWindow(target, frontmost: frontmost)
    }

    private func captureWindow(_ target: WindowInfo, frontmost: NSRunningApplication?) {
        isStarting = true
        Task {
            defer { isStarting = false }
            do {
                let captured = try await ScreenCaptureService.shared.captureWindow(target.id, includeShadow: settings.windowShadow)
                deliver(CaptureResult(image: captured.image, scale: captured.scale, kind: .window, screenRect: target.frame, appName: target.owner), frontmost: frontmost)
            } catch {
                ToastCenter.shared.showError("Window capture failed", error)
                restoreFocus(frontmost)
            }
        }
    }

    func repeatLastArea() {
        guard let area = settings.lastArea,
              let screen = NSScreen.screen(for: area.displayID) ?? NSScreen.screens.first(where: { $0.frame.intersects(area.rect) }),
              let displayID = screen.displayID
        else {
            beginOverlay(mode: .area, intent: .capture)
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
                deliver(CaptureResult(image: image, scale: snapshot.scale, kind: .area, screenRect: area.rect, appName: frontmost?.localizedName), frontmost: frontmost)
            } catch {
                ToastCenter.shared.showError("Capture failed", error)
            }
        }
    }

    // MARK: Outcomes

    private func handle(_ outcome: OverlayOutcome, intent: CaptureIntent, frontmost: NSRunningApplication?) {
        switch outcome {
        case .cancelled, .finished:
            restoreFocus(frontmost)
        case .display(let snapshot):
            deliver(CaptureResult(image: snapshot.image, scale: snapshot.scale, kind: .fullscreen, screenRect: snapshot.frame, appName: frontmost?.localizedName), frontmost: frontmost)
        case .window(let window):
            captureWindow(window, frontmost: frontmost)
        case .area(let snapshot, let rect):
            guard let image = snapshot.crop(rect) else {
                restoreFocus(frontmost)
                return
            }
            let screenRect = snapshot.globalRect(fromLocal: rect)
            switch intent {
            case .capture:
                settings.lastArea = StoredArea(rect: screenRect, displayID: snapshot.displayID)
                deliver(CaptureResult(image: image, scale: snapshot.scale, kind: .area, screenRect: screenRect, appName: frontmost?.localizedName), frontmost: frontmost)
            case .recognizeText:
                restoreFocus(frontmost)
                recognizeText(in: image)
            case .pin:
                restoreFocus(frontmost)
                PinWindowController.pin(image: image, scale: snapshot.scale, at: screenRect)
            case .scrolling:
                restoreFocus(frontmost)
                startScrolling(display: snapshot, region: rect)
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
    func deliver(_ result: CaptureResult, frontmost: NSRunningApplication?) {
        ShutterSound.play()
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
