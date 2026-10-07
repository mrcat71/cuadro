import AVFoundation
import AppKit
import CuadroKit
@preconcurrency import ScreenCaptureKit

/// Development aid: `Cuadro --ui-snapshot <dir>` opens the main windows with a synthetic
/// screenshot, captures Cuadro's own windows with ScreenCaptureKit and quits.
/// Requires the Screen Recording permission.
struct SnapshotCheckFailure: LocalizedError {
    let description: String
    var errorDescription: String? { description }
}

enum UISnapshotRunner {
    static func run(outputDirectory: URL) {
        Task {
            do {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                try await capture(into: outputDirectory)
            } catch {
                Log.app.error("UI snapshot failed: \(error.localizedDescription, privacy: .public)")
                FileHandle.standardError.write(Data("ui-snapshot failed: \(error.localizedDescription)\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }

    private static func capture(into directory: URL) async throws {
        let sample = sampleImage(width: 1600, height: 1000)
        EditorWindowController.open(CaptureResult(image: sample, scale: 2, kind: .file, title: "UI Snapshot"))
        try await Task.sleep(for: .milliseconds(600))
        if let model = (NSApp.windows.compactMap { $0.windowController as? EditorWindowController }.first?.model) {
            decorate(model)
        }
        ToastCenter.shared.show("Copied to clipboard", detail: "1600 × 1000 px", duration: 10)
        PinWindowController.pin(image: sample, scale: 4, at: nil)
        SettingsWindowController.shared.show()
        OnboardingWindowController.shared.show()
        ThumbnailOverlay.shared.show(CaptureResult(image: sample, scale: 2, kind: .area))
        let recordingChrome = showRecordingChrome()
        defer {
            for controller in recordingChrome { controller.debugDismiss() }
        }
        try checkRecordingControlsLevel()
        try await Task.sleep(for: .seconds(2))
        if let editor = (NSApp.windows.compactMap { $0.windowController as? EditorWindowController }.first) {
            // 100% whenever the screen fits the 800 × 500 pt sample; less means the initial fit broke.
            print("editor zoom \(Int((editor.model.zoom * 100).rounded()))%")
        }

        guard PermissionCenter.shared.hasScreenRecording else {
            // Without Screen Recording, render the layer trees in-process. Liquid Glass is a
            // window server effect, so glass surfaces appear flat in these images.
            for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let image = renderOffline(window) else { continue }
                let name = (window.title.isEmpty ? String(describing: type(of: window)) : window.title).replacingOccurrences(of: "/", with: "-")
                let url = directory.appendingPathComponent("\(index)-\(name).png")
                if let data = ImageExporter.encodePNG(image, scale: window.backingScaleFactor) {
                    try data.write(to: url)
                    print("wrote \(url.path) (offline render)")
                }
            }
            try await snapshotOverlay(into: directory)
            return
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = content.windows.filter { $0.owningApplication?.processID == ownPID && $0.frame.width > 60 && $0.isOnScreen }
        for (index, window) in windows.enumerated() {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(filter.contentRect.width * scale)
            configuration.height = Int(filter.contentRect.height * scale)
            configuration.shouldBeOpaque = false
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let name = (window.title?.isEmpty == false ? window.title! : "window-\(index)")
                .replacingOccurrences(of: "/", with: "-")
            let url = directory.appendingPathComponent("\(index)-\(name).png")
            guard let data = ImageExporter.encodePNG(image, scale: scale) else { continue }
            try data.write(to: url)
            print("wrote \(url.path) (\(image.width)x\(image.height), window frame \(window.frame))")
        }
        try await recordEditorWindow(windows, into: directory)
    }

    /// The recording frame being adjusted on the main screen, and the controls of a recording in
    /// progress around a second area. Nothing is recorded.
    private static func showRecordingChrome() -> [ScreenRecordingController] {
        guard let screen = NSScreen.main, let displayID = screen.displayID else { return [] }
        let display = RecordingDisplay(displayID: displayID, frame: screen.frame, scale: screen.backingScaleFactor)
        let adjusting = ScreenRecordingController(display: display, area: CGRect(x: 120, y: 160, width: 640, height: 360), microphone: true, returnFocus: {}) {}
        adjusting.begin()
        let recording = ScreenRecordingController(display: display, area: CGRect(x: 840, y: 160, width: 480, height: 300), microphone: true, returnFocus: {}) {}
        recording.debugShowRecordingControls()
        return [adjusting, recording]
    }

    /// The recording controls must stay above the dimmed screen of the adjust stage, or it takes
    /// their clicks. That happened once, when every FloatingPanel fell back to `.floating`.
    private static func checkRecordingControlsLevel() throws {
        guard let shield = NSApp.windows.first(where: { $0 is RecordingShieldWindow }) else { return }
        for controls in NSApp.windows where controls is RecordingControlsPanel && controls.level <= shield.level {
            throw SnapshotCheckFailure(description: "recording controls at window level \(controls.level.rawValue), not above the dimmed screen at \(shield.level.rawValue)")
        }
    }

    /// Records about two seconds through the RecordingSession that Record Screen uses: whole
    /// display frames showing only the editor window, cropped to part of it that pans across it
    /// the way dragging the recording controls does, with system audio, while switching tools so
    /// frames keep coming. Reads the movie back and saves its first and last frames.
    private static func recordEditorWindow(_ windows: [SCWindow], into directory: URL) async throws {
        guard let window = windows.first(where: { $0.title == "UI Snapshot" }),
              let model = (NSApp.windows.compactMap { $0.windowController as? EditorWindowController }.first?.model)
        else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) else { return }
        // Nothing but the editor window, so nothing else on the screen ends up in the movie.
        let filter = SCContentFilter(display: display, including: [window])
        let scale = CGFloat(filter.pointPixelScale)
        let frame = CGSize(width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale)
        // Both frames are global, y down.
        let editor = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY).intersection(CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height)))
        let crop = CGSize(width: CGFloat(Int(editor.width * scale * 0.6) & ~1), height: CGFloat(Int(editor.height * scale * 0.6) & ~1))
        let first = CGPoint(x: (editor.minX * scale).rounded(), y: (editor.minY * scale).rounded())
        let last = CGPoint(x: (editor.maxX * scale).rounded() - crop.width, y: (editor.maxY * scale).rounded() - crop.height)
        let url = directory.appendingPathComponent("recording.mp4")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let options = RecordingOptions(showsPointer: false, highlightsClicks: false, systemAudio: true)
        let session = try RecordingSession(filter: filter, frameSize: frame, crop: CGRect(origin: first, size: crop), options: options, outputURL: url)
        try await session.start()
        for (step, tool) in [EditorTool.ellipse, .text, .arrow, .rectangle].enumerated() {
            try await Task.sleep(for: .milliseconds(500))
            model.tool = tool
            let progress = CGFloat(step + 1) / 4
            session.move(cropOrigin: CGPoint(x: first.x + (last.x - first.x) * progress, y: first.y + (last.y - first.y) * progress))
        }
        // Lets the last pan settle.
        try await Task.sleep(for: .milliseconds(400))
        try await session.stop()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let size = try await video.first?.load(.naturalSize) ?? .zero
        let audioSeconds = try await audio.first?.load(.timeRange).duration.seconds ?? 0
        let frames = session.frameCounts
        print("wrote \(url.path) (recording, \(String(format: "%.1f", duration)) s, \(Int(size.width))x\(Int(size.height)) px from \(Int(frame.width))x\(Int(frame.height)) frames, \(frames.written) frames, \(frames.dropped) dropped, \(video.count) video and \(audio.count) audio tracks, audio \(String(format: "%.1f", audioSeconds)) s)")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (name, seconds) in [("recording-first", 0.0), ("recording-last", max(0, duration - 0.05))] {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            if let data = ImageExporter.encodePNG(image, scale: scale) {
                let frameURL = directory.appendingPathComponent("\(name).png")
                try data.write(to: frameURL)
                print("wrote \(frameURL.path) (movie frame at \(String(format: "%.2f", seconds)) s)")
            }
        }
    }

    /// Renders a window's content layer tree into an image.
    private static func renderOffline(_ window: NSWindow) -> CGImage? {
        guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { return nil }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard size.width > 0, size.height > 0,
              let ctx = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        if layer.isGeometryFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    /// Shows the selection overlay on the main screen with a synthetic frozen image.
    private static func snapshotOverlay(into directory: URL) async throws {
        guard let screen = NSScreen.main, let displayID = screen.displayID else { return }
        let scale = screen.backingScaleFactor
        let image = sampleImage(width: Int(screen.frame.width * scale), height: Int(screen.frame.height * scale))
        let snapshot = DisplaySnapshot(displayID: displayID, frame: screen.frame, scale: scale, image: image)
        let overlay = OverlayController(snapshots: [snapshot], windows: [], mode: .area, intent: .capture) { _ in }
        overlay.begin()
        overlay.debugSelect(CGRect(x: 240, y: 180, width: 520, height: 320), pointer: CGPoint(x: 760, y: 500))
        try await Task.sleep(for: .milliseconds(700))
        if let window = NSApp.windows.first(where: { $0 is OverlayWindow }), let rendered = renderOffline(window),
           let data = ImageExporter.encodePNG(rendered, scale: scale) {
            let url = directory.appendingPathComponent("overlay.png")
            try data.write(to: url)
            print("wrote \(url.path) (offline render)")
        }
        overlay.cancel()
    }

    /// Markup on the sample, in the 800 × 500 pt layout of `SampleBoard`: an incident told with
    /// Cuadro's tools.
    private static func decorate(_ model: EditorModel) {
        let token = Annotation(kind: .blur, start: CGPoint(x: 524, y: 432), end: CGPoint(x: 730, y: 453), style: model.style(for: .obscure))
        let node = Annotation(kind: .rectangle, start: CGPoint(x: 28, y: 431), end: CGPoint(x: 392, y: 453), style: model.style(for: .rectangle))
        let canary = Annotation(kind: .highlighter, start: CGPoint(x: 570, y: 271), end: CGPoint(x: 772, y: 292), style: model.style(for: .highlighter))
        let loupe = Annotation(kind: .magnifier, start: CGPoint(x: 258, y: 266), end: CGPoint(x: 326, y: 334), style: model.style(for: .magnifier))
        var spike = Annotation(kind: .counter, start: CGPoint(x: 292, y: 168), end: CGPoint(x: 259, y: 191), style: model.style(for: .counter))
        spike.number = 1
        var spikeNote = Annotation(kind: .text, start: CGPoint(x: 314, y: 192), style: model.style(for: .text))
        spikeNote.text = "p95 doubled after 4f2a1c"
        var drain = Annotation(kind: .counter, start: CGPoint(x: 410, y: 412), end: CGPoint(x: 393, y: 434), style: model.style(for: .counter))
        drain.number = 2
        var drainNote = Annotation(kind: .text, start: CGPoint(x: 226, y: 358), style: model.style(for: .text))
        drainNote.text = "Disk full · drain it"
        for annotation in [token, node, canary, loupe, spike, spikeNote, drain, drainNote] {
            model.add(annotation)
        }
        model.selectedID = nil
        model.tool = .arrow
    }

    /// The infrastructure dashboard sample (`SampleBoard`), at `width` × `height` pixels.
    static func sampleImage(width: Int, height: Int) -> CGImage {
        SampleBoard.image(width: width, height: height)
    }
}
