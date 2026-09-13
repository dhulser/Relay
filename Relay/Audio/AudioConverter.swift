import Foundation
import AVFoundation

/// Converts whatever the audio capture hands us into a target format.
///
/// Each engine needs something different — OpenAI's Realtime API wants 24 kHz
/// mono PCM16, while Apple's `SpeechAnalyzer` publishes its own preferred
/// format at runtime — so the target is a constructor argument rather than a
/// constant.
///
/// Nothing here assumes the input format. `AVAudioConverter` is rebuilt
/// whenever the input changes, so a device or output-route switch is handled.
///
/// The converter instance is deliberately long-lived: the sample-rate converter
/// keeps filter state between calls, and throwing it away per buffer would put
/// a click at every 20 ms boundary.
final class AudioConverter {

    /// What the OpenAI Realtime API accepts: PCM, signed 16-bit little endian,
    /// mono, 24 kHz. Int16 is native-endian, and every Mac we target is
    /// little-endian.
    static let openAIRealtimeFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ) else {
            fatalError("Could not build the 24 kHz mono PCM16 output format")
        }
        return format
    }()

    let targetFormat: AVAudioFormat

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var loggedTargetFormat = false

    init(target: AVAudioFormat) {
        self.targetFormat = target
    }

    /// Converts one buffer into the target format, or nil if it could not be
    /// converted.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }

        if inputFormat?.isEqual(buffer.format) != true {
            guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                Log.error(.audio, "Could not build converter from \(buffer.format)")
                return nil
            }
            self.converter = converter
            self.inputFormat = buffer.format
            Log.info(.audio, "Converter: \(Int(buffer.format.sampleRate)) Hz \(buffer.format.channelCount)ch → \(Self.describe(targetFormat))")
        }

        guard let converter else { return nil }

        // Resampling can round up, so leave slack beyond the exact ratio.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if suppliedInput {
                // One input buffer per call; tell the converter to drain and stop.
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            Log.error(.audio, "Conversion failed: \(conversionError?.localizedDescription ?? "unknown")")
            return nil
        }
        guard output.frameLength > 0 else { return nil }

        if !loggedTargetFormat {
            loggedTargetFormat = true
            Log.info(.audio, "Output: \(Self.describe(targetFormat))")
        }
        return output
    }

    /// Converts and flattens to raw bytes. Only valid for interleaved Int16
    /// targets, which is what the OpenAI path uses.
    func convertToPCM16Data(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let converted = convert(buffer), let samples = converted.int16ChannelData else { return nil }
        return Data(bytes: samples[0], count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
    }

    /// Drops resampler state so the next buffer starts a fresh stream.
    func reset() {
        converter?.reset()
    }

    static func describe(_ format: AVAudioFormat) -> String {
        let channels = format.channelCount == 1 ? "mono" : "\(format.channelCount)ch"
        let depth: String
        switch format.commonFormat {
        case .pcmFormatInt16: depth = "PCM16"
        case .pcmFormatInt32: depth = "PCM32"
        case .pcmFormatFloat32: depth = "Float32"
        case .pcmFormatFloat64: depth = "Float64"
        default: depth = "other"
        }
        return "\(Int(format.sampleRate)) Hz \(channels) \(depth)"
    }
}
