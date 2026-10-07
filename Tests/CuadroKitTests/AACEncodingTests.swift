import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import CuadroKit

struct AACEncodingTests {
    struct BitRateCase: Sendable, CustomTestStringConvertible {
        let name: String
        let preferred: Int
        let applicable: [Int]
        let expected: Int?
        var testDescription: String { name }
    }

    @Test(arguments: [
        BitRateCase(name: "preferred is accepted", preferred: 96_000, applicable: [64_000, 96_000, 128_000], expected: 96_000),
        BitRateCase(name: "highest below the preferred", preferred: 96_000, applicable: [16_000, 32_000, 64_000], expected: 64_000),
        BitRateCase(name: "unsorted", preferred: 96_000, applicable: [128_000, 48_000, 80_000], expected: 80_000),
        BitRateCase(name: "all above the preferred", preferred: 8_000, applicable: [24_000, 16_000], expected: 16_000),
        BitRateCase(name: "none accepted", preferred: 96_000, applicable: [], expected: nil),
    ])
    func bitRate(_ testCase: BitRateCase) {
        #expect(AACEncoding.bitRate(preferred: testCase.preferred, applicable: testCase.applicable) == testCase.expected)
    }

    struct Format: Sendable, CustomTestStringConvertible {
        let sampleRate: Double
        let channels: Int
        var testDescription: String { "\(Int(sampleRate)) Hz, \(channels) ch" }
    }

    /// Microphones as ScreenCaptureKit delivers them: Bluetooth headsets at 8, 16 and 24 kHz, where
    /// 96 kbps used to fail with "Cannot Encode Media", and built-in or USB ones at 44.1 and 48 kHz.
    @Test(arguments: [
        Format(sampleRate: 8_000, channels: 1),
        Format(sampleRate: 16_000, channels: 1),
        Format(sampleRate: 24_000, channels: 1),
        Format(sampleRate: 24_000, channels: 2),
        Format(sampleRate: 44_100, channels: 1),
        Format(sampleRate: 48_000, channels: 1),
        Format(sampleRate: 48_000, channels: 2),
    ])
    func microphoneSettingsEncode(_ format: Format) async throws {
        let preferred = format.channels == 1 ? 96_000 : 128_000
        let settings = AACEncoding.settings(sampleRate: format.sampleRate, channels: format.channels, preferredBitRate: preferred)
        let bitRate = try #require(settings[AVEncoderBitRateKey] as? Int)
        #expect(bitRate <= preferred)
        try await Self.encodeSilence(format, settings: settings)
    }

    /// Writes a fifth of a second of silence in `format` to an MP4 the way the recorder does.
    private static func encodeSilence(_ format: Format, settings: [String: Any]) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AACEncodingTests-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        try #require(writer.canAdd(input))
        writer.add(input)
        try #require(writer.startWriting(), "\(writer.error?.localizedDescription ?? "")")
        writer.startSession(atSourceTime: .zero)

        let pcm = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channels), interleaved: true
        ))
        let frames = Int(format.sampleRate) / 50
        for index in 0..<10 {
            for _ in 0..<200 where !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            let block = try CMBlockBuffer(length: frames * Int(pcm.streamDescription.pointee.mBytesPerFrame), flags: .assureMemoryNow)
            try block.fillDataBytes(with: 0)
            let sample = try CMSampleBuffer(
                dataBuffer: block, formatDescription: pcm.formatDescription, numSamples: frames,
                presentationTimeStamp: CMTime(value: CMTimeValue(index * frames), timescale: CMTimeScale(format.sampleRate)),
                packetDescriptions: []
            )
            try #require(input.append(sample), "\(writer.error?.localizedDescription ?? "append failed")")
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(writer.error?.localizedDescription ?? "")")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
