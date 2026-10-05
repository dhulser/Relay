import Foundation
import AVFoundation

/// Where the voice is played. One player node into this process's output,
/// which in the in-room configuration is the speakers and, once Relay Voice
/// exists, is what the virtual microphone taps.
final class VoiceOutputService {

    /// Every synthesizer converts to this, so buffers can be scheduled as
    /// they arrive with no per-buffer format negotiation. 24 kHz because that
    /// is what the OpenAI voice is generated at.
    static let format: AVAudioFormat = {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                         channels: 1, interleaved: false) else {
            fatalError("Could not build the 24 kHz mono Float32 format")
        }
        return format
    }()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var running = false
    /// Bumped on every interrupt so a completion from a stopped utterance is
    /// recognised and ignored.
    private var generation = 0

    func start() throws {
        guard !running else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.format)
        engine.prepare()
        try engine.start()
        player.play()
        running = true
        Log.info(.speak, "Voice output started")
    }

    func stop() {
        guard running else { return }
        player.stop()
        engine.stop()
        engine.detach(player)
        running = false
        Log.info(.speak, "Voice output stopped")
    }

    /// Queues one buffer; playback starts on the first one.
    func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard running else { return }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    /// Calls back on the main queue once everything queued so far has been
    /// heard. Scheduled as a short silent buffer so it lands after the last
    /// real one, whichever that turned out to be.
    func whenDrained(_ completion: @escaping () -> Void) {
        guard running,
              let silence = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 240) else {
            DispatchQueue.main.async(execute: completion)
            return
        }
        silence.frameLength = 240
        let expected = generation
        player.scheduleBuffer(silence, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == expected else { return }
                completion()
            }
        }
        if !player.isPlaying { player.play() }
    }

    /// Drops whatever is queued, for when the user starts talking again.
    func interrupt() {
        guard running else { return }
        generation += 1
        player.stop()
        player.play()
    }
}
