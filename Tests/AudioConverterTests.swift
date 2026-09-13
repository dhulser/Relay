import XCTest
import AVFoundation
@testable import Relay

final class AudioConverterTests: XCTestCase {

    /// The Realtime API accepts exactly one input shape: PCM, signed 16-bit
    /// little endian, mono, 24 kHz. Assert every part of that, not just the
    /// sample rate — a big-endian or float format would still "be 24 kHz".
    func testTargetFormatIsMono24kSignedInt16LittleEndian() {
        let format = AudioConverter.openAIRealtimeFormat
        XCTAssertEqual(format.sampleRate, 24_000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatInt16)

        let asbd = format.streamDescription.pointee
        XCTAssertEqual(asbd.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(asbd.mBitsPerChannel, 16)
        XCTAssertEqual(asbd.mBytesPerFrame, 2)
        XCTAssertEqual(asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger, kAudioFormatFlagIsSignedInteger,
                       "must be signed integer PCM")
        XCTAssertEqual(asbd.mFormatFlags & kAudioFormatFlagIsFloat, 0, "must not be float")
        XCTAssertEqual(asbd.mFormatFlags & kAudioFormatFlagIsBigEndian, 0, "must be little endian")
    }

    /// Feed exactly what ScreenCaptureKit delivers on this Mac — 48 kHz stereo
    /// Float32 non-interleaved, in 20 ms buffers — and check the output really
    /// is one second of 24 kHz mono PCM16.
    func testConvertsScreenCaptureKitFormatToOneSecondOf24kMono() {
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                  channels: 2, interleaved: false)!
        let converter = AudioConverter(target: AudioConverter.openAIRealtimeFormat)

        var output = Data()
        for i in 0..<50 {
            let buffer = Self.sineBuffer(format: input, frames: 960, frequency: 440,
                                         startFrame: i * 960, amplitude: 0.5)
            guard let converted = converter.convertToPCM16Data(buffer) else {
                return XCTFail("conversion returned nil for buffer \(i)")
            }
            output.append(converted)
        }

        // 1 s of 24 kHz mono Int16 = 48,000 bytes. Allow slack for resampler priming.
        XCTAssertEqual(Double(output.count), 48_000, accuracy: 2_000)
        XCTAssertEqual(output.count % 2, 0, "Int16 samples must not be split across a chunk boundary")
    }

    /// A 0.5-amplitude sine should land near 0.5/√2 of full scale. This is the
    /// endianness check with teeth: byte-swapped Int16 would wreck the RMS long
    /// before the frame count noticed anything.
    func testAmplitudeSurvivesConversion() {
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                  channels: 2, interleaved: false)!
        let converter = AudioConverter(target: AudioConverter.openAIRealtimeFormat)

        var samples: [Int16] = []
        for i in 0..<50 {
            let buffer = Self.sineBuffer(format: input, frames: 960, frequency: 440,
                                         startFrame: i * 960, amplitude: 0.5)
            guard let data = converter.convertToPCM16Data(buffer) else { continue }
            samples.append(contentsOf: data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) })
        }

        XCTAssertGreaterThan(samples.count, 20_000)

        // Skip the resampler's warm-up before measuring.
        let measured = samples.dropFirst(2_000)
        let sumOfSquares = measured.reduce(0.0) { $0 + pow(Double($1), 2) }
        let rms = (sumOfSquares / Double(measured.count)).squareRoot()
        let expected = 0.5 / 2.0.squareRoot() * 32_767

        XCTAssertEqual(rms, expected, accuracy: expected * 0.1)
    }

    /// A mid-session output-device change alters the input format; the converter
    /// has to rebuild rather than return nil forever.
    func testRebuildsWhenInputFormatChanges() {
        let converter = AudioConverter(target: AudioConverter.openAIRealtimeFormat)

        let stereo48k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                      channels: 2, interleaved: false)!
        let mono44k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                    channels: 1, interleaved: false)!

        XCTAssertNotNil(converter.convertToPCM16Data(Self.sineBuffer(format: stereo48k, frames: 960,
                                                          frequency: 440, startFrame: 0, amplitude: 0.5)))
        XCTAssertNotNil(converter.convertToPCM16Data(Self.sineBuffer(format: mono44k, frames: 882,
                                                          frequency: 440, startFrame: 0, amplitude: 0.5)))
    }

    func testRejectsEmptyBuffer() {
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                  channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 960)!
        buffer.frameLength = 0
        XCTAssertNil(AudioConverter(target: AudioConverter.openAIRealtimeFormat).convert(buffer))
    }

    // MARK: - Helpers

    /// Continuous sine across buffers — `startFrame` keeps the phase unbroken so
    /// the resampler sees a real signal rather than 50 discontinuities.
    private static func sineBuffer(format: AVAudioFormat, frames: AVAudioFrameCount,
                                   frequency: Double, startFrame: Int, amplitude: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames

        let channels = buffer.floatChannelData!
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                let t = Double(startFrame + frame) / format.sampleRate
                channels[channel][frame] = amplitude * Float(sin(2 * .pi * frequency * t))
            }
        }
        return buffer
    }
}
