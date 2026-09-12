import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation
import CoreGraphics

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplayFound
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Live Translator needs Screen Recording permission to capture system audio."
        case .noDisplayFound:
            return "No display available to capture audio from."
        case .streamFailed(let detail):
            return detail
        }
    }
}

/// Captures all system audio via ScreenCaptureKit.
///
/// Video is not requested (no `.screen` output is attached), so the stream costs
/// almost nothing — ScreenCaptureKit just needs a display-backed filter to exist.
/// This app's own audio is excluded, and the microphone is never captured.
/// Nothing is written to disk; buffers live only long enough to hand off.
final class SystemAudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate {

    /// Audio in whatever format ScreenCaptureKit chose. Delivered on the
    /// capture queue, never on main — each engine converts to what it needs.
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// 0…1 RMS level, delivered on the main queue for the UI meter.
    var onLevel: ((Float) -> Void)?

    /// Fatal capture problems. Delivered on the main queue.
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "co.kevel.LiveTranslator.audio", qos: .userInitiated)

    // Diagnostics
    private var loggedInputFormat = false
    private var buffersSeen = 0
    private var levelAccumulator: Float = 0
    private var levelSamples = 0
    private var lastLevelLog = Date.distantPast

    // MARK: - Permission

    /// True if Screen Recording has already been granted. Does not prompt.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt if the user has never been asked. Returns the
    /// current grant state — which is `false` on the very first ask, because
    /// macOS only applies the grant to a fresh launch of the app.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard Self.hasPermission else {
            Self.requestPermission()
            throw CaptureError.permissionDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            // SCK reports a permission problem as a generic stream error.
            Log.error(.audio, "Could not read shareable content: \(error.localizedDescription)")
            throw CaptureError.permissionDenied
        }

        guard let display = content.displays.first else { throw CaptureError.noDisplayFound }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        // Video is never consumed; keep the frame path as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()

        self.stream = stream
        resetDiagnostics()
        Log.info(.audio, "Capture started")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
            Log.info(.audio, "Capture stopped")
        } catch {
            Log.error(.audio, "Stop failed: \(error.localizedDescription)")
        }
    }

    private func resetDiagnostics() {
        loggedInputFormat = false
        buffersSeen = 0
        levelAccumulator = 0
        levelSamples = 0
        lastLevelLog = .distantPast
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }

        if !loggedInputFormat {
            loggedInputFormat = true
            let f = buffer.format
            let layout = f.isInterleaved ? "interleaved" : "non-interleaved"
            let channels = f.channelCount == 1 ? "mono" : (f.channelCount == 2 ? "stereo" : "\(f.channelCount)ch")
            Log.info(.audio, "Input: \(Int(f.sampleRate)) Hz \(channels), \(Self.name(for: f.commonFormat)) \(layout)")
        }

        buffersSeen += 1
        if buffersSeen <= 3 {
            Log.info(.audio, "Buffer \(buffersSeen): \(buffer.frameLength) frames (\(String(format: "%.1f", Double(buffer.frameLength) / buffer.format.sampleRate * 1000)) ms)")
        }

        reportLevel(for: buffer)
        onAudioBuffer?(buffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // `stop()` clears `self.stream` before calling stopCapture, and stopping
        // deliberately still lands here as "The user stopped the stream". A nil
        // stream means we asked for this, so it is not an error.
        guard self.stream != nil else { return }

        Log.error(.audio, "Stream stopped with error: \(error.localizedDescription)")
        self.stream = nil
        DispatchQueue.main.async { [weak self] in
            self?.onError?(CaptureError.streamFailed(error.localizedDescription))
        }
    }

    // MARK: - Level meter

    private func reportLevel(for buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for ch in 0..<Int(buffer.format.channelCount) {
            let data = channels[ch]
            for i in 0..<frames { sum += data[i] * data[i] }
        }
        let rms = sqrt(sum / Float(frames * Int(buffer.format.channelCount)))

        levelAccumulator = max(levelAccumulator, rms)
        levelSamples += 1

        let now = Date()
        guard now.timeIntervalSince(lastLevelLog) >= 0.5 else { return }
        lastLevelLog = now

        let peak = levelAccumulator
        let meter = Self.meterBar(for: peak)
        Log.info(.audio, "level \(meter) peak=\(String(format: "%.4f", peak)) buffers=\(levelSamples)")

        levelAccumulator = 0
        levelSamples = 0
        DispatchQueue.main.async { [weak self] in self?.onLevel?(peak) }
    }

    private static func meterBar(for rms: Float) -> String {
        // Log scale: -60 dBFS floor up to 0.
        let db = 20 * log10(max(rms, 0.000_001))
        let filled = Int(((db + 60) / 60 * 20).rounded())
        let clamped = min(max(filled, 0), 20)
        return String(repeating: "█", count: clamped) + String(repeating: "·", count: 20 - clamped)
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbd)
        else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            Log.error(.audio, "CMSampleBufferCopyPCMDataIntoAudioBufferList failed: \(status)")
            return nil
        }
        return buffer
    }

    private static func name(for format: AVAudioCommonFormat) -> String {
        switch format {
        case .pcmFormatFloat32: return "Float32"
        case .pcmFormatFloat64: return "Float64"
        case .pcmFormatInt16: return "Int16"
        case .pcmFormatInt32: return "Int32"
        default: return "other"
        }
    }
}
