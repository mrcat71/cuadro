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

    /// The recording frame being adjusted on the main screen, with a camera bubble that shows a
    /// placeholder, and the controls of a recording in progress around a second area. Nothing is
    /// recorded, and the camera stays off.
    private static func showRecordingChrome() -> [ScreenRecordingController] {
        guard let screen = NSScreen.main, let displayID = screen.displayID else { return [] }
        let display = RecordingDisplay(displayID: displayID, frame: screen.frame, scale: screen.backingScaleFactor)
        let adjusting = ScreenRecordingController(display: display, area: CGRect(x: 120, y: 160, width: 640, height: 360), microphone: true, camera: false, returnFocus: {}) {}
        adjusting.begin()
        adjusting.debugShowCameraPlaceholder()
        let recording = ScreenRecordingController(display: display, area: CGRect(x: 840, y: 160, width: 480, height: 300), microphone: true, camera: false, returnFocus: {}) {}
        recording.debugShowRecordingControls()
        return [adjusting, recording]
    }

    /// The recording controls and the camera bubble must stay above the dimmed screen of the
    /// adjust stage, or it takes their clicks. That happened once, when every FloatingPanel fell
    /// back to `.floating`.
    private static func checkRecordingControlsLevel() throws {
        guard let shield = NSApp.windows.first(where: { $0 is RecordingShieldWindow }) else { return }
        for controls in NSApp.windows where (controls is RecordingControlsPanel || controls is CameraBubblePanel) && controls.level <= shield.level {
            throw SnapshotCheckFailure(description: "\(type(of: controls)) at window level \(controls.level.rawValue), not above the dimmed screen at \(shield.level.rawValue)")
        }
    }

    /// Records about two seconds through the RecordingSession that Record Screen uses: whole
    /// display frames showing only the editor window and a camera bubble on it, cropped to part of
    /// the window that pans across it the way dragging the recording controls does, with system
    /// audio, while switching tools so frames keep coming. Pauses for 0.6 s halfway. Reads the
    /// movie back, saves its first and last frames and says whether the bubble is in them.
    private static func recordEditorWindow(_ windows: [SCWindow], into directory: URL) async throws {
        guard let editorWindow = windows.first(where: { $0.title == "UI Snapshot" }),
              let editorController = (NSApp.windows.compactMap { $0.windowController as? EditorWindowController }.first),
              let editorScreen = editorController.window?.screen, let editorDisplayID = editorScreen.displayID,
              let editorFrame = editorController.window?.frame
        else { return }
        let model = editorController.model
        // A bubble in the middle of the window, where every crop of the pan includes it.
        let bubbleDisplay = RecordingDisplay(displayID: editorDisplayID, frame: editorScreen.frame, scale: editorScreen.backingScaleFactor)
        let bubble = CameraBubble(mirrored: false, placeholder: true)
        bubble.place(in: ScreenCoordinates.localTopLeft(fromCocoa: editorFrame, screenFrame: editorScreen.frame), on: bubbleDisplay, anchor: CGPoint(x: 0.5, y: 0.5))
        defer { bubble.remove() }
        let content = try await ScreenCaptureService.shared.shareableContent(listing: [bubble.panel])
        guard let window = content.windows.first(where: { $0.windowID == editorWindow.windowID }),
              let display = content.displays.first(where: { $0.frame.intersects(window.frame) })
        else { return }
        let bubbleWindows = content.windows.filter { $0.windowID == CGWindowID(bubble.panel.windowNumber) }
        // Every app left out, Cuadro's too, but for the editor window and the bubble, so nothing
        // else on the screen ends up in the movie. The bubble gets in the way Record Screen lets
        // it in: as an exception to its app being left out.
        let filter = SCContentFilter(display: display, excludingApplications: content.applications, exceptingWindows: [window] + bubbleWindows)
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
        let session = try RecordingSession(source: RecordingSource(displayID: display.displayID, filter: filter, frameSize: frame), crop: CGRect(origin: first, size: crop), options: options, outputURL: url)
        try await session.start()
        let started = ContinuousClock.now
        let pause = Duration.milliseconds(600)
        for (step, tool) in [EditorTool.ellipse, .text, .arrow, .rectangle].enumerated() {
            try await Task.sleep(for: .milliseconds(500))
            model.tool = tool
            let progress = CGFloat(step + 1) / 4
            session.move(cropOrigin: CGPoint(x: first.x + (last.x - first.x) * progress, y: first.y + (last.y - first.y) * progress))
            if step == 1 {
                // Frames keep coming while paused, and none of them may reach the movie.
                session.pause()
                try await Task.sleep(for: pause / 2)
                model.tool = .pen
                try await Task.sleep(for: pause / 2)
                session.resume()
            }
        }
        // Lets the last pan settle.
        try await Task.sleep(for: .milliseconds(400))
        try await session.stop()
        let wall = (ContinuousClock.now - started).milliseconds / 1000
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let size = try await video.first?.load(.naturalSize) ?? .zero
        let audioSeconds = try await audio.first?.load(.timeRange).duration.seconds ?? 0
        let frames = session.frameCounts
        print("wrote \(url.path) (recording, \(String(format: "%.1f", duration)) s of \(String(format: "%.1f", wall)) s with a \(String(format: "%.1f", pause.milliseconds / 1000)) s pause, \(Int(size.width))x\(Int(size.height)) px from \(Int(frame.width))x\(Int(frame.height)) frames, \(frames.written) frames, \(frames.dropped) dropped, \(video.count) video and \(audio.count) audio tracks, audio \(String(format: "%.1f", audioSeconds)) s)")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // The bubble's center in frame pixels, y down, and where the first and last crops start.
        let bubbleCenter = ScreenCoordinates.localTopLeft(fromCocoa: bubble.panel.frame, screenFrame: editorScreen.frame)
        let center = CGPoint(x: bubbleCenter.midX * scale, y: bubbleCenter.midY * scale)
        for (name, seconds, origin) in [("recording-first", 0.0, first), ("recording-last", max(0, duration - 0.05), last)] {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            let bubbleShown = bubbleWindows.isEmpty ? "not listed" : showsBubble(image, at: CGPoint(x: center.x - origin.x, y: center.y - origin.y), radius: bubbleCenter.width / 2 * scale) ? "yes" : "no"
            if let data = ImageExporter.encodePNG(image, scale: scale) {
                let frameURL = directory.appendingPathComponent("\(name).png")
                try data.write(to: frameURL)
                print("wrote \(frameURL.path) (movie frame at \(String(format: "%.2f", seconds)) s, camera bubble: \(bubbleShown))")
            }
        }
    }

    /// The placeholder bubble's dark gray between its person symbol and its ring, at the lower
    /// right of `center` in `image` (pixels, y down).
    private static func showsBubble(_ image: CGImage, at center: CGPoint, radius: CGFloat) -> Bool {
        let point = CGPoint(x: center.x + radius * 0.55, y: center.y + radius * 0.55)
        guard point.x >= 0, point.y >= 0, Int(point.x) < image.width, Int(point.y) < image.height,
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        // Draws the image so that `point` lands on the single pixel; CoreGraphics is y up.
        context.draw(image, in: CGRect(x: -point.x.rounded(.down), y: point.y.rounded(.down) - CGFloat(image.height) + 1, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        // NSColor(white: 0.2) in sRGB, give or take the video encoding.
        return (0..<3).allSatisfy { abs(Int(data[$0]) - 51) <= 14 }
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
