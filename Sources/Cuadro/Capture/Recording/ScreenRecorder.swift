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

/// A display a recording can show: its stream's content filter and the pixels of its frames.
struct RecordingSource {
    let displayID: CGDirectDisplayID
    let filter: SCContentFilter
    let frameSize: CGSize
}

/// One screen recording. Each SCStream captures whole frames (of a display, or of a window for the
/// UI self-check) and `RecordingWriter` crops them to the recorded area before encoding, so the
/// area can move while recording, also onto another display: that display gets a stream of its
/// own, and the movie shows its frames from then on. Apple's SCRecordingOutput cannot do that: any
/// change to the stream configuration ends its movie.
final class RecordingSession {
    let outputURL: URL
    private let writer: RecordingWriter
    private let options: RecordingOptions
    /// The stream the recording started with, which also records the audio.
    private let firstStream: SCStream
    /// One stream per display the area has been on, kept running so the area can come back.
    private var streams: [CGDirectDisplayID: SCStream]
    /// Streams of other displays that are still starting; `stop` waits for them.
    private var startingStreams: [Task<Void, Never>] = []

    /// - Parameter crop: the recorded area in the source's frame pixels; its size is the movie's
    ///   and stays fixed.
    init(source: RecordingSource, crop: CGRect, options: RecordingOptions, outputURL: URL) throws {
        self.outputURL = outputURL
        self.options = options
        writer = try RecordingWriter(url: outputURL, movieSize: crop.size, systemAudio: options.systemAudio, microphone: options.microphone)
        firstStream = SCStream(filter: source.filter, configuration: Self.configuration(frameSize: source.frameSize, options: options, audio: true), delegate: writer)
        streams = [source.displayID: firstStream]
        writer.setTarget(source: ObjectIdentifier(firstStream), crop: crop)
    }

    private static func configuration(frameSize: CGSize, options: RecordingOptions, audio: Bool) -> SCStreamConfiguration {
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
        // Only the first stream records sound, so each audio track has one source.
        if audio {
            configuration.capturesAudio = options.systemAudio
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.captureMicrophone = options.microphone
        }
        return configuration
    }

    /// Called on the main actor when the recording stops by itself, e.g. a display went away.
    var onFailure: (@MainActor (Error) -> Void)? {
        get { writer.onFailure }
        set { writer.onFailure = newValue }
    }

    func start() async throws {
        try writer.begin()
        do {
            try firstStream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            if options.systemAudio {
                try firstStream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
            }
            if options.microphone {
                try firstStream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
            }
            try await firstStream.startCapture()
        } catch {
            writer.cancel()
            throw error
        }
    }

    /// Pans the recording to the crop whose top-left pixel is `origin`, on the display it shows.
    /// The movie eases there over a few frames instead of jumping.
    func move(cropOrigin origin: CGPoint) {
        writer.setTarget(origin)
    }

    /// Shows `source`'s display from now on, cropped to `crop` in its frame pixels; the movie
    /// scales a crop of another size to its own. The first visit to a display starts a stream for
    /// it, and the movie holds its last picture until that stream's first frame.
    func move(to source: RecordingSource, crop: CGRect) {
        if let stream = streams[source.displayID] {
            writer.setTarget(source: ObjectIdentifier(stream), crop: crop)
            return
        }
        let stream = SCStream(filter: source.filter, configuration: Self.configuration(frameSize: source.frameSize, options: options, audio: false), delegate: writer)
        do {
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        } catch {
            writer.reportFailure(error)
            return
        }
        streams[source.displayID] = stream
        writer.setTarget(source: ObjectIdentifier(stream), crop: crop)
        let writer = writer
        startingStreams.append(Task {
            do {
                try await stream.startCapture()
            } catch {
                // The movie would hold the last picture for good; end the recording instead.
                writer.reportFailure(error)
            }
        })
    }

    /// Stops capturing and returns once the movie file is complete.
    func stop() async throws {
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        // A stream still starting would keep capturing after the movie ends.
        for task in startingStreams {
            await task.value
        }
        for stream in streams.values {
            do {
                try await stream.stopCapture()
            } catch {
                // Already stopped by an error; the frames written so far still make a movie.
                Log.capture.error("Stopping a recording stream failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        try await writer.finish(at: end)
    }

    /// Frames written and dropped so far, for the log.
    var frameCounts: (written: Int, dropped: Int) { writer.frameCounts }
}

/// Crops each captured frame to the recorded area and writes it, with the audio, to an MP4. Only
/// frames of the stream the area is on reach the movie. ScreenCaptureKit delivers samples on
/// `queue`, where all writing happens; only the crop target arrives from the main actor, through
/// a lock.
nonisolated final class RecordingWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "io.github.mrcat71.cuadro.recording", qos: .userInitiated)
    var onFailure: (@MainActor (Error) -> Void)?

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let microphone: AVAssetWriterInput?
    private let systemAudio: AVAssetWriterInput?
    /// The stream whose frames the movie shows and where the crop should go in them.
    private let target = Mutex(Target(source: nil, crop: .zero))
    private let counts = Mutex((written: 0, dropped: 0))

    private nonisolated struct Target {
        var source: ObjectIdentifier?
        /// In the source's frame pixels.
        var crop: CGRect
    }

    /// Where the crop is, easing towards the target while it stays on one stream.
    private var origin = CGPoint.zero
    private var originSource: ObjectIdentifier?
    private var originTime = CMTime.invalid
    /// The stream and crop of the last frame written.
    private var appended: (source: ObjectIdentifier, crop: CGRect)?
    private var transfer: VTPixelTransferSession?
    /// The newest picture of each stream: cropped again while the area moves over a still screen,
    /// and shown at once when the area comes back to that stream's display.
    private var lastFrames: [ObjectIdentifier: CVPixelBuffer] = [:]
    private var lastVideoTime = CMTime.invalid
    private var sessionStart = CMTime.invalid
    private var repeater: DispatchSourceTimer?
    private var failed = false

    /// How fast the crop catches up with the frame: a third of the way in about 30 ms.
    private static let smoothing: TimeInterval = 0.08

    init(url: URL, movieSize: CGSize, systemAudio: Bool, microphone: Bool) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let width = Int(movieSize.width)
        let height = Int(movieSize.height)
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

    /// Pans the crop to `origin` on the stream shown now.
    func setTarget(_ origin: CGPoint) {
        target.withLock { $0.crop.origin = origin }
    }

    /// Shows `source`'s frames from now on, cropped to `crop`.
    func setTarget(source: ObjectIdentifier, crop: CGRect) {
        target.withLock { $0 = Target(source: source, crop: crop) }
    }

    /// Ends the recording early, as a stream that stops with an error does.
    func reportFailure(_ error: Error) {
        queue.async { [self] in fail(error) }
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
        lastFrames = [:]
        if let transfer {
            VTPixelTransferSessionInvalidate(transfer)
            self.transfer = nil
        }
    }

    // MARK: SCStreamOutput, SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen: capture(sampleBuffer, from: ObjectIdentifier(stream))
        case .microphone: append(sampleBuffer, to: microphone)
        case .audio: append(sampleBuffer, to: systemAudio)
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        reportFailure(error)
    }

    // MARK: Writing

    private func capture(_ sampleBuffer: CMSampleBuffer, from source: ObjectIdentifier) {
        // Idle frames only say that nothing changed; they carry no picture.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[SCStreamFrameInfo.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let picture = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        lastFrames[source] = picture
        write(picture, from: source, at: sampleBuffer.presentationTimeStamp)
    }

    /// The area moves over a screen that does not change, so ScreenCaptureKit sends no frames:
    /// crop the last picture again, about 60 times a second, until the crop arrives. Also shows
    /// the last picture of a display the area comes back to.
    private func repeatWhileMoving() {
        guard sessionStart.isValid, !failed else { return }
        let goal = target.withLock { $0 }
        guard let source = goal.source, let picture = lastFrames[source] else { return }
        let settled = originSource == source && origin == goal.crop.origin
            && appended?.source == source && appended?.crop == Self.crop(at: goal.crop.origin, size: goal.crop.size, in: picture)
        guard !settled else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        // A captured frame went out moments ago.
        guard !lastVideoTime.isValid || (now - lastVideoTime).seconds >= 0.015 else { return }
        write(picture, from: source, at: now)
    }

    /// Writes `picture` if it comes from the stream the movie shows.
    private func write(_ picture: CVPixelBuffer, from source: ObjectIdentifier, at time: CMTime) {
        let goal = target.withLock { $0 }
        guard !failed, writer.status == .writing, let transfer, goal.source == source else { return }
        if !sessionStart.isValid {
            writer.startSession(atSourceTime: time)
            sessionStart = time
        } else if lastVideoTime.isValid, time <= lastVideoTime {
            return
        }
        advanceOrigin(to: goal.crop.origin, on: source, at: time)
        guard video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else {
            counts.withLock { $0.dropped += 1 }
            return
        }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else {
            counts.withLock { $0.dropped += 1 }
            return
        }
        let crop = Self.crop(at: origin, size: goal.crop.size, in: picture)
        let width = CGFloat(CVPixelBufferGetWidth(picture))
        let height = CGFloat(CVPixelBufferGetHeight(picture))
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
        appended = (source, crop)
        counts.withLock { $0.written += 1 }
    }

    /// The crop of `size` at `origin` in whole pixels, so a crop of the movie's size copies 1:1
    /// and stays sharp, kept inside `picture`.
    private static func crop(at origin: CGPoint, size: CGSize, in picture: CVPixelBuffer) -> CGRect {
        let width = CGFloat(CVPixelBufferGetWidth(picture))
        let height = CGFloat(CVPixelBufferGetHeight(picture))
        return CGRect(
            x: min(max(origin.x.rounded(), 0), max(0, width - size.width)),
            y: min(max(origin.y.rounded(), 0), max(0, height - size.height)),
            width: size.width, height: size.height
        )
    }

    private func advanceOrigin(to goal: CGPoint, on source: ObjectIdentifier, at time: CMTime) {
        // On another display's frames the crop starts where it belongs; easing only pans.
        guard originSource == source else {
            origin = goal
            originSource = source
            originTime = time
            return
        }
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
