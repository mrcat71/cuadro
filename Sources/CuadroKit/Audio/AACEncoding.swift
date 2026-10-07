import AVFAudio
import Foundation

/// AAC settings for a movie's audio tracks. The encoder accepts fewer bit rates the lower the
/// sample rate: a Bluetooth headset microphone at 24 kHz mono takes at most 64 kbps, and a bit
/// rate it does not take makes AVAssetWriter fail with "Cannot Encode Media" on the first sample.
public enum AACEncoding {
    /// `AVAssetWriterInput` output settings for `sampleRate` and `channels`, at `preferredBitRate`
    /// or the nearest bit rate below it that the encoder accepts. Without any (an unknown format),
    /// the settings name no bit rate and the encoder uses its default.
    public static func settings(sampleRate: Double, channels: Int, preferredBitRate: Int) -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        let applicable = applicableBitRates(sampleRate: sampleRate, channels: channels)
        if let bitRate = bitRate(preferred: preferredBitRate, applicable: applicable) {
            settings[AVEncoderBitRateKey] = bitRate
        }
        return settings
    }

    /// Bit rates in bits per second that the AAC encoder accepts for `sampleRate` and `channels`;
    /// empty when it does not encode that format.
    public static func applicableBitRates(sampleRate: Double, channels: Int) -> [Int] {
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)),
              let aac = AVAudioFormat(settings: [
                  AVFormatIDKey: kAudioFormatMPEG4AAC,
                  AVSampleRateKey: sampleRate,
                  AVNumberOfChannelsKey: channels,
              ]),
              let converter = AVAudioConverter(from: pcm, to: aac)
        else { return [] }
        return converter.applicableEncodeBitRates?.map(\.intValue) ?? []
    }

    /// The highest of `applicable` up to `preferred`, else the lowest of them; nil when empty.
    public static func bitRate(preferred: Int, applicable: [Int]) -> Int? {
        applicable.filter { $0 <= preferred }.max() ?? applicable.min()
    }
}
