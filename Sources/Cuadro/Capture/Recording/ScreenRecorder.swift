import AVFoundation
import AppKit
import CoreMedia
import CuadroKit
@preconcurrency import ScreenCaptureKit
import Synchronization
import VideoToolbox

/// What a recording includes besides the picture.
struct RecordingOptions {
    var showsPointer = true
    var highlightsClicks = true
    var systemAudio = false
    var microphone = false

    /// The Settings > Capture choices, with the microphone of the Record Screen variant used.
    static func current(microphone: Bool) -> RecordingOptions {
        let settings = AppSettings.shared
        return RecordingOptions(
            showsPointer: settings.recordPointer,
            highlightsClicks: settings.recordClicks,
            systemAudio: settings.recordSystemAudio,
            microphone: microphone
        )
    }
}

enum RecordingError: LocalizedError {
    case cannotWrite(String)
    case noFrames

    var errorDescription: String? {
        switch self {
        case .cannotWrite(let detail): "The movie could not be written (\(detail))."
        case .noFrames: "Nothing was recorded."
        }
    }
}

/// One screen recording. The SCStream captures whole frames (a display, or a window for the UI
/// self-check) and `RecordingWriter` crops each one to the recorded area before encoding it, so
/// the area can move while recording. Apple's SCRecordingOutput cannot do that: any change to the
/// stream configuration ends its movie.
final class RecordingSession {
    let outputURL: URL
    private let stream: SCStream
    private let writer: RecordingWriter
    private let options: RecordingOptions

    /// - Parameters:
    ///   - frameSize: pixels of each captured frame.
    ///   - crop: the recorded area in those pixels; its size is the movie's and stays fixed.
    init(filter: SCContentFilter, frameSize: CGSize, crop: CGRect, options: RecordingOptions, outputURL: URL) throws {
        self.outputURL = outputURL
        self.options = options
        let configuration = SCStreamConfiguration()
        configuration.width = Int(frameSize.width)
        configuration.height = Int(frameSize.height)
        // BGRA is also what click highlighting needs.
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 8
        configuration.showsCursor = options.showsPointer
        configuration.showMouseClicks = options.highlightsClicks
        configuration.capturesAudio = options.systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = options.microphone
        writer = try RecordingWriter(url: outputURL, crop: crop, frameSize: frameSize, systemAudio: options.systemAudio, microphone: options.microphone)
        stream = SCStream(filter: filter, configuration: configuration, delegate: writer)
    }

    /// Called on the main actor when the recording stops by itself, e.g. a display went away.
    var onFailure: (@MainActor (Error) -> Void)? {
        get { writer.onFailure }
        set { writer.onFailure = newValue }
    }

    func start() async throws {
        try writer.begin()
        do {
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            if options.systemAudio {
                try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
            }
            if options.microphone {
                try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
            }
            try await stream.startCapture()
        } catch {
            writer.cancel()
            throw error
        }
    }

    /// Pans the recording to the crop whose top-left pixel is `origin`. The movie eases there
    /// over a few frames instead of jumping.
    func move(cropOrigin origin: CGPoint) {
        writer.setTarget(origin)
    }

    /// Stops capturing and returns once the movie file is complete.
    func stop() async throws {
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        do {
            try await stream.stopCapture()
        } catch {
            // Already stopped by an error; the frames written so far still make a movie.
            Log.capture.error("Stopping the recording stream failed: \(error.localizedDescription, privacy: .public)")
        }
        try await writer.finish(at: end)
    }

    /// Frames written and dropped so far, for the log.
    var frameCounts: (written: Int, dropped: Int) { writer.frameCounts }
}

/// Crops each captured frame to the recorded area and writes it, with the audio, to an MP4.
/// ScreenCaptureKit delivers samples on `queue`, where all writing happens; only the crop target
/// arrives from the main actor, through a lock.
nonisolated final class RecordingWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "io.github.mrcat71.cuadro.recording", qos: .userInitiated)
    var onFailure: (@MainActor (Error) -> Void)?

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let microphone: AVAssetWriterInput?
    private let systemAudio: AVAssetWriterInput?
    private let cropSize: CGSize
    private let frameSize: CGSize
    /// Where the crop should go, in frame pixels.
    private let target: Mutex<CGPoint>
    private let counts = Mutex((written: 0, dropped: 0))

    /// Where the crop is, easing towards `target`.
    private var origin: CGPoint
    private var originTime = CMTime.invalid
    private var appendedOrigin: CGPoint?
    private var transfer: VTPixelTransferSession?
    /// The newest captured picture, cropped again while the area moves over a still screen.
    private var lastFrame: CVPixelBuffer?
    private var lastVideoTime = CMTime.invalid
    private var sessionStart = CMTime.invalid
    private var repeater: DispatchSourceTimer?
    private var failed = false

    /// How fast the crop catches up with the frame: a third of the way in about 30 ms.
    private static let smoothing: TimeInterval = 0.08

    init(url: URL, crop: CGRect, frameSize: CGSize, systemAudio: Bool, microphone: Bool) throws {
        cropSize = crop.size
        self.frameSize = frameSize
        origin = crop.origin
        target = Mutex(crop.origin)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let width = Int(crop.width)
        let height = Int(crop.height)
        // H.264 plays everywhere but stops at about 4K; larger areas need HEVC.
        let hevc = width > 4096 || height > 2304
        let bitsPerPixel = hevc ? 0.06 : 0.1
        let bitRate = min(max(Double(width * height) * 60 * bitsPerPixel, 2_000_000), 120_000_000)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(bitRate),
            AVVideoExpectedSourceFrameRateKey: 60,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if !hevc {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ])
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        // The microphone goes first: players that only play one audio track then play the voice.
        self.microphone = microphone ? AVAssetWriterInput(mediaType: .audio, outputSettings: Self.microphoneSettings()) : nil
        self.systemAudio = systemAudio ? AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000,
        ]) : nil
        super.init()
        for input in [video, self.microphone, self.systemAudio].compactMap({ $0 }) {
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecordingError.cannotWrite("unsupported \(input.mediaType.rawValue) settings")
            }
            writer.add(input)
        }
    }

    /// AAC in the microphone's own rate and channel count (ScreenCaptureKit delivers the device's
    /// native format), within what AAC takes: up to 48 kHz, two channels and, at the 8 to 24 kHz
    /// of a Bluetooth headset, less than the usual bit rate.
    private static func microphoneSettings() -> [String: Any] {
        var sampleRate = 48_000.0
        var channels = 1
        if let format = AVCaptureDevice.default(for: .audio)?.activeFormat.formatDescription.audioStreamBasicDescription {
            if format.mSampleRate >= 8_000 { sampleRate = min(format.mSampleRate, 48_000) }
            channels = min(max(Int(format.mChannelsPerFrame), 1), 2)
        }
        let settings = AACEncoding.settings(sampleRate: sampleRate, channels: channels, preferredBitRate: channels == 1 ? 96_000 : 128_000)
        let bitRate = (settings[AVEncoderBitRateKey] as? Int).map { "\($0 / 1000) kbps" } ?? "the encoder's default bit rate"
        Log.capture.notice("Microphone track: \(Int(sampleRate)) Hz, \(channels) ch, AAC at \(bitRate, privacy: .public)")
        return settings
    }

    var frameCounts: (written: Int, dropped: Int) { counts.withLock { $0 } }

    func begin() throws {
        var session: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        guard status == noErr, let session else { throw RecordingError.cannotWrite("pixel transfer \(status)") }
        // The crop is the source's clean aperture, copied 1:1 into a movie-sized buffer.
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_CropSourceToCleanAperture)
        guard writer.startWriting() else {
            VTPixelTransferSessionInvalidate(session)
            throw writer.error ?? RecordingError.cannotWrite("writer status \(writer.status.rawValue)")
        }
        queue.sync {
            transfer = session
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.repeatWhileMoving() }
            timer.resume()
            repeater = timer
        }
    }

    func setTarget(_ point: CGPoint) {
        let clamped = CGPoint(
            x: min(max(point.x, 0), max(0, frameSize.width - cropSize.width)),
            y: min(max(point.y, 0), max(0, frameSize.height - cropSize.height))
        )
        target.withLock { $0 = clamped }
    }

    func cancel() {
        queue.sync {
            tearDown()
            if writer.status == .writing { writer.cancelWriting() }
        }
    }

    /// Ends the movie at `end` (host time), so a still screen at the end keeps its full length.
    func finish(at end: CMTime) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                tearDown()
                guard writer.status == .writing, sessionStart.isValid else {
                    let error = writer.error ?? RecordingError.noFrames
                    if writer.status == .writing { writer.cancelWriting() }
                    continuation.resume(throwing: error)
                    return
                }
                for input in [video, microphone, systemAudio].compactMap({ $0 }) {
                    input.markAsFinished()
                }
                writer.endSession(atSourceTime: lastVideoTime.isValid ? max(end, lastVideoTime) : end)
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: writer.error ?? RecordingError.cannotWrite("writer status \(writer.status.rawValue)"))
                    }
                }
            }
        }
    }

    private func tearDown() {
        repeater?.cancel()
        repeater = nil
        lastFrame = nil
        if let transfer {
            VTPixelTransferSessionInvalidate(transfer)
            self.transfer = nil
        }
    }

    // MARK: SCStreamOutput, SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen: capture(sampleBuffer)
        case .microphone: append(sampleBuffer, to: microphone)
        case .audio: append(sampleBuffer, to: systemAudio)
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async { [self] in fail(error) }
    }

    // MARK: Writing

    private func capture(_ sampleBuffer: CMSampleBuffer) {
        // Idle frames only say that nothing changed; they carry no picture.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[SCStreamFrameInfo.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let picture = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        lastFrame = picture
        write(picture, at: sampleBuffer.presentationTimeStamp)
    }

    /// The area moves over a screen that does not change, so ScreenCaptureKit sends no frames:
    /// crop the last picture again, about 60 times a second, until the crop arrives.
    private func repeatWhileMoving() {
        guard let lastFrame, sessionStart.isValid, !failed else { return }
        let goal = target.withLock { $0 }
        guard appendedOrigin != goal || origin != goal else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        // A captured frame went out moments ago.
        guard !lastVideoTime.isValid || (now - lastVideoTime).seconds >= 0.015 else { return }
        write(lastFrame, at: now)
    }

    private func write(_ picture: CVPixelBuffer, at time: CMTime) {
        guard !failed, writer.status == .writing, let transfer else { return }
        if !sessionStart.isValid {
            writer.startSession(atSourceTime: time)
            sessionStart = time
        } else if lastVideoTime.isValid, time <= lastVideoTime {
            return
        }
        advanceOrigin(to: time)
        guard video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else {
            counts.withLock { $0.dropped += 1 }
            return
        }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else {
            counts.withLock { $0.dropped += 1 }
            return
        }
        // Whole pixels, so the copy is 1:1 and stays sharp.
        let width = CGFloat(CVPixelBufferGetWidth(picture))
        let height = CGFloat(CVPixelBufferGetHeight(picture))
        let crop = CGRect(
            x: min(max(origin.x.rounded(), 0), max(0, width - cropSize.width)),
            y: min(max(origin.y.rounded(), 0), max(0, height - cropSize.height)),
            width: cropSize.width, height: cropSize.height
        )
        // Clean aperture offsets run from the picture's center to the crop's center, y down.
        let aperture: [CFString: Any] = [
            kCVImageBufferCleanApertureWidthKey: crop.width,
            kCVImageBufferCleanApertureHeightKey: crop.height,
            kCVImageBufferCleanApertureHorizontalOffsetKey: crop.midX - width / 2,
            kCVImageBufferCleanApertureVerticalOffsetKey: crop.midY - height / 2,
        ]
        CVBufferSetAttachment(picture, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldNotPropagate)
        let status = VTPixelTransferSessionTransferImage(transfer, from: picture, to: output)
        guard status == noErr else {
            fail(RecordingError.cannotWrite("pixel transfer \(status)"))
            return
        }
        guard adaptor.append(output, withPresentationTime: time) else {
            fail(writer.error ?? RecordingError.cannotWrite("video append"))
            return
        }
        lastVideoTime = time
        appendedOrigin = crop.origin
        counts.withLock { $0.written += 1 }
    }

    private func advanceOrigin(to time: CMTime) {
        let goal = target.withLock { $0 }
        // A long still stretch counts as one short step, so motion after it starts gently.
        let elapsed = originTime.isValid ? min(max((time - originTime).seconds, 0), 0.1) : 0
        origin = Smoothing.approach(origin, to: goal, elapsed: elapsed, timeConstant: Self.smoothing, snapDistance: 0.5)
        originTime = time
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, !failed, writer.status == .writing, sessionStart.isValid,
              sampleBuffer.dataReadiness == .ready,
              sampleBuffer.presentationTimeStamp >= sessionStart,
              input.isReadyForMoreMediaData
        else { return }
        if !input.append(sampleBuffer) {
            fail(writer.error ?? RecordingError.cannotWrite("audio append"))
        }
    }

    private func fail(_ error: Error) {
        guard !failed else { return }
        failed = true
        repeater?.cancel()
        repeater = nil
        Log.capture.error("Recording failed: \(error.localizedDescription, privacy: .public)")
        guard let onFailure else { return }
        Task { @MainActor in onFailure(error) }
    }
}
