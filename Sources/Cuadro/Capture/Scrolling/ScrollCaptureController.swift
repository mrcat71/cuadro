import AppKit
import CoreMedia
import CuadroKit
@preconcurrency import ScreenCaptureKit
import SwiftUI

@Observable
final class ScrollCaptureModel {
    var height = 0
    var status = "Scroll up or down slowly to capture"
    var preview: NSImage?
    var isAutoScrolling = false
    /// Set by the first scroll; the capture only grows that way.
    var direction: ScrollDirection?
}

/// Scrolling capture: streams the selected region, stitches frames as the user (or auto-scroll)
/// scrolls, and hands the tall image to the regular capture pipeline.
final class ScrollCaptureController {
    private let display: DisplaySnapshot
    private let region: CGRect
    private let completion: (CaptureResult?) -> Void
    private let model = ScrollCaptureModel()
    private let output = StreamFrameOutput()
    private let worker: StitchWorker
    private var stream: SCStream?
    private var consumer: Task<Void, Never>?
    private var borderPanel: FloatingPanel?
    private var hudPanel: FloatingPanel?
    private var autoScrollTimer: Timer?
    private var lastProgress = Date()
    private var isFinishing = false
    /// Stitch outcomes per kind, logged when the capture ends to explain short results.
    private var outcomeCounts: [String: Int] = [:]

    /// - Parameter region: display-local y-down rect in points.
    init(display: DisplaySnapshot, region: CGRect, completion: @escaping (CaptureResult?) -> Void) {
        self.display = display
        self.region = region
        self.completion = completion
        worker = StitchWorker(maxHeight: AppSettings.shared.scrollMaxHeight, colorSpace: display.image.colorSpace)
    }

    private var globalRegion: CGRect { display.globalRect(fromLocal: region) }

    func start() {
        showChrome()
        Task {
            do {
                try await startStream()
            } catch {
                ToastCenter.shared.showError("Scrolling capture failed", error)
                finish(save: false)
            }
        }
    }

    private func startStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.displayID }) else {
            throw CaptureError.noDisplays
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: scDisplay, excludingApplications: ownApps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region
        configuration.width = Int((region.width * display.scale).rounded())
        configuration.height = Int((region.height * display.scale).rounded())
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        configuration.queueDepth = 4
        configuration.captureResolution = .best
        if AppSettings.shared.convertToSRGB {
            configuration.colorSpaceName = CGColorSpace.sRGB
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        self.stream = stream

        let frames = output.frames
        let worker = worker
        consumer = Task { [weak self] in
            for await frame in frames {
                let progress = await worker.add(frame)
                guard let self, !Task.isCancelled else { return }
                self.handle(progress)
            }
        }
        try await stream.startCapture()
    }

    private func handle(_ progress: StitchWorker.Progress) {
        model.height = progress.height
        model.direction = progress.direction
        outcomeCounts[progress.outcome.logName, default: 0] += 1
        if let preview = progress.preview {
            model.preview = NSImage(cgImage: preview, scale: 1)
        }
        switch progress.outcome {
        case .started:
            lastProgress = Date()
        case .appended:
            lastProgress = Date()
            model.status = model.isAutoScrolling ? "Auto-scrolling…" : "Capturing… keep scrolling"
        case .unchanged, .sizeMismatch:
            break
        case .scrolledBack:
            model.status = model.direction == .up ? "Scroll up to continue" : "Scroll down to continue"
        case .lostTrack:
            model.status = "Too fast: scroll back a little"
        case .limitReached:
            model.status = "Reached the \(AppSettings.shared.scrollMaxHeight.formatted()) px limit"
            stopAutoScroll()
        }
    }

    // MARK: Auto-scroll

    func toggleAutoScroll() {
        if autoScrollTimer != nil {
            stopAutoScroll()
            return
        }
        guard PermissionCenter.shared.hasAccessibility else {
            PermissionCenter.shared.requestAccessibility()
            model.status = "Allow Accessibility for Cuadro, then try again"
            return
        }
        let target = ScreenCoordinates(primaryScreenHeight: NSScreen.primaryHeight).flip(globalRegion.center)
        CGWarpMouseCursorPosition(target)
        lastProgress = Date()
        model.isAutoScrolling = true
        model.status = "Auto-scrolling…"
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoScrollTick(at: target) }
        }
    }

    private func autoScrollTick(at location: CGPoint) {
        if Date().timeIntervalSince(lastProgress) > 1.6 {
            stopAutoScroll()
            model.status = "Reached the end. Press Done."
            return
        }
        // Positive wheel values scroll up; keep going the way the user started.
        let step = Int32(max(4, 36 * AppSettings.shared.autoScrollSpeed))
        let pixels = model.direction == .up ? step : -step
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        event.location = location
        event.post(tap: .cghidEventTap)
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        model.isAutoScrolling = false
    }

    // MARK: Finish

    func finish(save: Bool) {
        guard !isFinishing else { return }
        isFinishing = true
        stopAutoScroll()
        let counts = outcomeCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let direction = model.direction.map { "\($0)" } ?? "none"
        Log.capture.notice("Scrolling capture \(save ? "done" : "cancelled", privacy: .public): \(self.model.height) px, direction \(direction, privacy: .public), frames: \(counts, privacy: .public)")
        Task {
            if let stream {
                do {
                    try await stream.stopCapture()
                } catch {
                    Log.capture.error("stopCapture failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            output.finish()
            consumer?.cancel()
            removeChrome()
            var result: CaptureResult?
            if save {
                if let image = await worker.finalImage() {
                    result = CaptureResult(image: image, scale: display.scale, kind: .scrolling, screenRect: nil, appName: nil, title: "Scrolling Capture")
                } else {
                    ToastCenter.shared.show("Nothing was captured", detail: "Scroll the selected area before pressing Done.", style: .warning)
                }
            }
            completion(result)
        }
    }

    // MARK: Chrome

    private func showChrome() {
        let border = FloatingPanel(level: .statusBar, clickThrough: true)
        border.host(ScrollBorderView(size: globalRegion.size))
        border.setFrame(globalRegion.insetBy(dx: -6, dy: -6), display: false)
        border.orderFrontRegardless()
        borderPanel = border

        let hud = FloatingPanel(level: .statusBar, allowsKey: true)
        hud.host(ScrollHUDView(
            model: model,
            onAutoScroll: { [weak self] in self?.toggleAutoScroll() },
            onDone: { [weak self] in self?.finish(save: true) },
            onCancel: { [weak self] in self?.finish(save: false) }
        ))
        let size = hud.frame.size
        let screen = display.frame
        var origin = CGPoint(x: globalRegion.maxX + 10, y: globalRegion.maxY - size.height)
        if origin.x + size.width > screen.maxX { origin.x = globalRegion.minX - size.width - 10 }
        if origin.x < screen.minX { origin.x = globalRegion.maxX - size.width - 10 }
        origin.y = min(max(origin.y, screen.minY + 10), screen.maxY - size.height - 10)
        hud.setFrameOrigin(origin)
        hud.orderFrontRegardless()
        hud.makeKey()
        hudPanel = hud
    }

    private func removeChrome() {
        borderPanel?.orderOut(nil)
        hudPanel?.orderOut(nil)
        borderPanel = nil
        hudPanel = nil
    }
}

/// Serializes stitching off the main actor.
actor StitchWorker {
    struct Progress: Sendable {
        let outcome: StitchOutcome
        let height: Int
        let direction: ScrollDirection?
        let preview: CGImage?
    }

    private let stitcher: ScrollStitcher
    private let colorSpace: CGColorSpace
    private var lastPreview = Date.distantPast
    private static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

    init(maxHeight: Int, colorSpace: CGColorSpace?) {
        stitcher = ScrollStitcher(maxHeight: maxHeight)
        self.colorSpace = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }

    func add(_ frame: StitchFrame) -> Progress {
        let outcome = stitcher.add(frame)
        var preview: CGImage?
        let grew: Bool
        switch outcome {
        case .started, .appended, .limitReached: grew = true
        default: grew = false
        }
        if grew, Date().timeIntervalSince(lastPreview) > 0.25 {
            preview = stitcher.previewImage(maxWidth: 180, colorSpace: colorSpace, bitmapInfo: Self.bitmapInfo)
            lastPreview = Date()
        }
        return Progress(outcome: outcome, height: stitcher.height, direction: stitcher.direction, preview: preview)
    }

    func finalImage() -> CGImage? {
        stitcher.makeImage(colorSpace: colorSpace, bitmapInfo: Self.bitmapInfo)
    }
}

/// Receives ScreenCaptureKit frames on a private queue and forwards complete ones in order.
nonisolated final class StreamFrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "io.github.mrcat71.cuadro.scrolling")
    let frames: AsyncStream<StitchFrame>
    private let continuation: AsyncStream<StitchFrame>.Continuation

    override init() {
        (frames, continuation) = AsyncStream.makeStream(of: StitchFrame.self, bufferingPolicy: .bufferingNewest(2))
        super.init()
    }

    func finish() {
        continuation.finish()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let frame = Self.makeFrame(sampleBuffer) else { return }
        continuation.yield(frame)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Log.capture.error("Scrolling stream stopped: \(error.localizedDescription, privacy: .public)")
        continuation.finish()
    }

    private static func makeFrame(_ sampleBuffer: CMSampleBuffer) -> StitchFrame? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[SCStreamFrameInfo.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        pixels.withUnsafeMutableBytes { target in
            guard let destination = target.baseAddress else { return }
            for row in 0..<height {
                memcpy(destination + row * rowBytes, base + row * bytesPerRow, rowBytes)
            }
        }
        return StitchFrame(width: width, height: height, pixels: pixels)
    }
}

private extension StitchOutcome {
    var logName: String {
        switch self {
        case .started: "started"
        case .appended: "appended"
        case .unchanged: "unchanged"
        case .scrolledBack: "scrolledBack"
        case .lostTrack: "lostTrack"
        case .limitReached: "limitReached"
        case .sizeMismatch: "sizeMismatch"
        }
    }
}

struct ScrollBorderView: View {
    let size: CGSize
    @State private var phase: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6], dashPhase: phase))
            .frame(width: size.width + 12, height: size.height + 12)
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { phase = -14 }
            }
    }
}

struct ScrollHUDView: View {
    let model: ScrollCaptureModel
    let onAutoScroll: () -> Void
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                if let preview = model.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 150, maxHeight: 220, alignment: model.direction == .up ? .top : .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: "arrow.down.to.line.compact")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, height: 220)
            Text("\(model.height.formatted()) px")
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 150)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onAutoScroll) {
                Label(model.isAutoScrolling ? "Stop" : "Auto-Scroll", systemImage: model.isAutoScrolling ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            HStack(spacing: 8) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Done", action: onDone)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 190)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(12)
    }
}
