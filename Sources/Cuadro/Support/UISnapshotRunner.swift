import AppKit
import CuadroKit
@preconcurrency import ScreenCaptureKit

/// Development aid: `Cuadro --ui-snapshot <dir>` opens the main windows with a synthetic
/// screenshot, captures Cuadro's own windows with ScreenCaptureKit and quits.
/// Requires the Screen Recording permission.
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
        try await Task.sleep(for: .seconds(2))

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
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let name = (window.title?.isEmpty == false ? window.title! : "window-\(index)")
                .replacingOccurrences(of: "/", with: "-")
            let url = directory.appendingPathComponent("\(index)-\(name).png")
            guard let data = ImageExporter.encodePNG(image, scale: scale) else { continue }
            try data.write(to: url)
            print("wrote \(url.path) (\(image.width)x\(image.height), window frame \(window.frame))")
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

    private static func decorate(_ model: EditorModel) {
        var arrow = Annotation(kind: .arrow, start: CGPoint(x: 120, y: 90), end: CGPoint(x: 330, y: 200), style: model.style(for: .arrow))
        arrow.bend = CGPoint(x: 260, y: 110)
        let rectangle = Annotation(kind: .rectangle, start: CGPoint(x: 360, y: 160), end: CGPoint(x: 560, y: 260), style: model.style(for: .rectangle))
        var text = Annotation(kind: .text, start: CGPoint(x: 90, y: 300), style: model.style(for: .text))
        text.text = "Liquid Glass markup"
        var counter = Annotation(kind: .counter, start: CGPoint(x: 620, y: 120), style: model.style(for: .counter))
        counter.number = 1
        let pixelate = Annotation(kind: .pixelate, start: CGPoint(x: 600, y: 300), end: CGPoint(x: 760, y: 380), style: model.style(for: .obscure))
        let highlight = Annotation(kind: .highlighter, start: CGPoint(x: 80, y: 400), end: CGPoint(x: 400, y: 430), style: model.style(for: .highlighter))
        for annotation in [arrow, rectangle, text, counter, pixelate, highlight] {
            model.add(annotation)
        }
        model.selectedID = rectangle.id
        model.tool = .rectangle
    }

    /// A fake app window on a colorful background.
    static func sampleImage(width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: space, colors: [RGBAColor(hex: "#4F7CFF")!.cgColor, RGBAColor(hex: "#E85DBA")!.cgColor] as CFArray, locations: nil)!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let card = CGRect(x: 160, y: 140, width: width - 320, height: height - 280)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.96))
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: 28, cornerHeight: 28, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(RGBAColor(hex: "#E5E7EB")!.cgColor)
        for row in 0..<8 {
            ctx.fill(CGRect(x: card.minX + 60, y: card.maxY - 140 - CGFloat(row) * 70, width: card.width - 120 - CGFloat(row % 3) * 120, height: 26))
        }
        ctx.setFillColor(RGBAColor(hex: "#007AFF")!.cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: card.minX + 60, y: card.minY + 60, width: 220, height: 56), cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.fillPath()
        return ctx.makeImage()!
    }
}
