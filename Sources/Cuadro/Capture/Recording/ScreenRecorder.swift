import AVFoundation
import AppKit
import CoreMedia
import CuadroKit
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// One screen recording: an SCStream that writes straight to a movie file through
/// SCRecordingOutput, so no frames pass through Cuadro.
final class RecordingSession {
    let outputURL: URL
    private let stream: SCStream
    private let output: SCRecordingOutput
    private let events = RecordingEvents()

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, outputURL: URL) {
        self.outputURL = outputURL
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = outputURL
        recording.outputFileType = .mp4
        // H.264 plays everywhere but stops at about 4K; larger areas need HEVC.
        recording.videoCodecType = configuration.width > 4096 || configuration.height > 2304 ? .hevc : .h264
        output = SCRecordingOutput(configuration: recording, delegate: events)
        stream = SCStream(filter: filter, configuration: configuration, delegate: events)
    }

    /// Called on the main actor when the recording stops by itself, e.g. a display went away.
    var onFailure: (@MainActor (Error) -> Void)? {
        get { events.onFailure }
        set { events.onFailure = newValue }
    }

    func start() async throws {
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
    }

    /// Stops capturing and returns once the movie file is complete.
    func stop() async throws {
        try await stream.stopCapture()
        try await events.finished()
    }
}

/// Stream and recording callbacks, which arrive on ScreenCaptureKit's queues.
nonisolated final class RecordingEvents: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?
    var onFailure: (@MainActor (Error) -> Void)?

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        resolve(.success(()))
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        fail(error)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        fail(error)
    }

    func finished() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    private func fail(_ error: Error) {
        let isFirst = resolve(.failure(error))
        guard isFirst, let onFailure else { return }
        Task { @MainActor in onFailure(error) }
    }

    @discardableResult
    private func resolve(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return false
        }
        outcome = result
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(with: result)
        return true
    }
}

extension SCStreamConfiguration {
    /// Recording of `region` (display-local y-down points) with the user's recording settings.
    static func recording(region: CGRect, scale: CGFloat) -> SCStreamConfiguration {
        let settings = AppSettings.shared
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region
        // Video encoders want even dimensions.
        configuration.width = max(2, Int((region.width * scale).rounded()) & ~1)
        configuration.height = max(2, Int((region.height * scale).rounded()) & ~1)
        // BGRA is also what click highlighting needs.
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 8
        configuration.captureResolution = .best
        configuration.showsCursor = settings.recordPointer
        configuration.showMouseClicks = settings.recordClicks
        configuration.capturesAudio = settings.recordSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = settings.recordMicrophone && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        return configuration
    }
}

@Observable
final class RecordingHUDModel {
    var elapsed: TimeInterval = 0
    var isStopping = false
}

/// The recording in progress: a border around the area, the timer with a Stop button, and the
/// movie saved to the screenshots folder at the end.
final class ScreenRecordingController {
    private let session: RecordingSession
    /// Cocoa global rect of the recorded area, and the frame of its display.
    private let area: CGRect
    private let screenFrame: CGRect
    private let model = RecordingHUDModel()
    private let completion: () -> Void
    private var borderPanel: FloatingPanel?
    private var hudPanel: FloatingPanel?
    private var timer: Timer?
    private var startDate = Date()
    private var isStopping = false

    var elapsed: TimeInterval { Date().timeIntervalSince(startDate) }

    init(session: RecordingSession, area: CGRect, screenFrame: CGRect, completion: @escaping () -> Void) {
        self.session = session
        self.area = area
        self.screenFrame = screenFrame
        self.completion = completion
    }

    func start() async throws {
        session.onFailure = { [weak self] error in
            self?.abort(error)
        }
        showChrome()
        do {
            try await session.start()
        } catch {
            removeChrome()
            throw error
        }
        startDate = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.elapsed = self.elapsed
            }
        }
        Log.capture.notice("Recording started: \(Int(self.area.width)) × \(Int(self.area.height)) pt")
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        model.isStopping = true
        timer?.invalidate()
        let duration = elapsed
        Task {
            removeChrome()
            do {
                try await session.stop()
                let saved = try Self.save(session.outputURL)
                Pasteboard.copy(fileURL: saved)
                Log.capture.notice("Recording saved: \(duration, format: .fixed(precision: 1)) s")
                ToastCenter.shared.show("Recording saved and copied", detail: saved.lastPathComponent, symbol: "film")
                NSWorkspace.shared.activateFileViewerSelecting([saved])
            } catch {
                ToastCenter.shared.showError("Recording failed", error)
            }
            completion()
        }
    }

    private func abort(_ error: Error) {
        guard !isStopping else { return }
        isStopping = true
        timer?.invalidate()
        removeChrome()
        ToastCenter.shared.showError("Recording stopped", error)
        completion()
    }

    /// Moves the finished movie into the screenshots folder under a unique name.
    private static func save(_ temporary: URL) throws -> URL {
        let settings = AppSettings.shared
        let folder = settings.saveFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = FileNameTemplate.render("Screen Recording {date} at {time}", context: .init())
        let url = FileNameTemplate.uniqueFileURL(directory: folder, baseName: name, pathExtension: "mp4") {
            FileManager.default.fileExists(atPath: $0.path)
        }
        try FileManager.default.moveItem(at: temporary, to: url)
        return url
    }

    // MARK: Chrome

    private func showChrome() {
        let border = FloatingPanel(level: .statusBar, clickThrough: true)
        border.host(RecordingBorderView(size: area.size))
        border.setFrame(area.insetBy(dx: -4, dy: -4), display: false)
        border.orderFrontRegardless()
        borderPanel = border

        let hud = FloatingPanel(level: .statusBar)
        hud.host(RecordingHUDView(model: model) { [weak self] in self?.stop() })
        let size = hud.frame.size
        // Below the area if there is room, else above it, else inside its bottom edge.
        var origin = CGPoint(x: area.midX - size.width / 2, y: area.minY - size.height - 10)
        if origin.y < screenFrame.minY + 8 { origin.y = area.maxY + 10 }
        if origin.y + size.height > screenFrame.maxY - 8 { origin.y = area.minY + 12 }
        origin.x = min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)
        hud.setFrameOrigin(origin)
        hud.orderFrontRegardless()
        hudPanel = hud
    }

    private func removeChrome() {
        borderPanel?.orderOut(nil)
        hudPanel?.orderOut(nil)
        borderPanel = nil
        hudPanel = nil
    }
}

struct RecordingBorderView: View {
    let size: CGSize

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Color.red, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .frame(width: size.width + 8, height: size.height + 8)
    }
}

struct RecordingHUDView: View {
    let model: RecordingHUDModel
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(Self.format(model.elapsed))
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityLabel("Recording, \(Int(model.elapsed)) seconds")
            Button(action: stop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .disabled(model.isStopping)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(10)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
