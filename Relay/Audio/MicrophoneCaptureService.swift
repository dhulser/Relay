import AVFoundation

/// The microphone as a source, for subtitling a conversation in the room.
///
/// Uses the default input device through AVAudioEngine and hands buffers to
/// the same pipeline the system tap feeds. Nothing is recorded; buffers live
/// only long enough to be handed on.
final class MicrophoneCaptureService: AudioCapturing {

    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onError: ((Error) -> Void)?

    private var engine: AVAudioEngine?
    private var levelPeak: Float = 0
    private var lastLevelReport = Date.distantPast
    private var loggedFormat = false

    func start() async throws {
        // Asks the first time; returns the standing answer after that.
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw CaptureError.microphoneDenied }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.unsupportedFormat
        }

        loggedFormat = false
        levelPeak = 0
        lastLevelReport = .distantPast

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.deviceFailed(OSStatus((error as NSError).code))
        }
        self.engine = engine
        Log.info(.audio, "Microphone capture started")
    }

    func stop() async {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        Log.info(.audio, "Microphone capture stopped")
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        if !loggedFormat {
            loggedFormat = true
            Log.info(.audio, "Microphone: \(AudioConverter.describe(buffer.format))")
        }

        if let channels = buffer.floatChannelData {
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for frame in 0..<frames { sum += channels[0][frame] * channels[0][frame] }
            levelPeak = max(levelPeak, (sum / Float(max(frames, 1))).squareRoot())
            let now = Date()
            if now.timeIntervalSince(lastLevelReport) >= 0.5 {
                lastLevelReport = now
                let peak = levelPeak
                levelPeak = 0
                DispatchQueue.main.async { [weak self] in self?.onLevel?(peak) }
            }
        }
        onAudioBuffer?(buffer)
    }
}
