import Foundation
import AVFoundation

/// Where the voice is played. Two player nodes into this process's output:
/// one for the synthesised voice, one that copies the real microphone
/// through when the key is up, so a call app that has picked Relay Voice as
/// its microphone still hears you between translations. In the in-room
/// configuration the output is the speakers; on a call, Relay Voice taps it.
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

    /// Pass-through may run this far behind live before buffers are dropped
    /// to catch up. The input and output clocks are not the same crystal.
    private static let maximumBacklog: AVAudioFramePosition = 24_000 * 15 / 100

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let passThrough = AVAudioPlayerNode()
    private let passThroughConverter = AudioConverter(target: VoiceOutputService.format)
    private var running = false
    /// Bumped on every interrupt so a completion from a stopped utterance is
    /// recognised and ignored.
    private var generation = 0

    // Pass-through bookkeeping, touched on the capture thread.
    private var passThroughScheduled: AVAudioFramePosition = 0
    private var passThroughDropped = 0
    private var passThroughLogged = false

    var isRunning: Bool { running }

    func start() throws {
        guard !running else { return }
        engine.attach(player)
        engine.attach(passThrough)
        engine.connect(player, to: engine.mainMixerNode, format: Self.format)
        engine.connect(passThrough, to: engine.mainMixerNode, format: Self.format)
        engine.prepare()
        try engine.start()
        player.play()
        running = true
        Log.info(.speak, "Voice output started")
    }

    func stop() {
        guard running else { return }
        player.stop()
        passThrough.stop()
        engine.stop()
        engine.detach(player)
        engine.detach(passThrough)
        running = false
        passThroughScheduled = 0
        passThroughConverter.reset()
        Log.info(.speak, "Voice output stopped")
    }

    // MARK: - The voice

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

    // MARK: - Pass-through

    /// Copies one microphone buffer to the output. Capture thread. Latency is
    /// one capture buffer plus the output's own; if the output clock falls
    /// behind the input's, buffers are dropped rather than letting the delay
    /// grow for the length of a call.
    func passThrough(_ buffer: AVAudioPCMBuffer) {
        guard running, let converted = passThroughConverter.convert(buffer) else { return }

        if let nodeTime = passThrough.lastRenderTime,
           let played = passThrough.playerTime(forNodeTime: nodeTime) {
            let backlog = passThroughScheduled - played.sampleTime
            if backlog > Self.maximumBacklog {
                passThroughDropped += 1
                if passThroughDropped % 50 == 1 {
                    Log.info(.speak, "Pass-through \(Int(Double(backlog) / Self.format.sampleRate * 1000)) ms behind; dropping a buffer")
                }
                return
            }
        }

        passThrough.scheduleBuffer(converted)
        passThroughScheduled += AVAudioFramePosition(converted.frameLength)
        if !passThrough.isPlaying {
            passThrough.play()
            passThroughScheduled = AVAudioFramePosition(converted.frameLength)
        }
        if !passThroughLogged {
            passThroughLogged = true
            Log.info(.speak, "Pass-through running")
        }
    }

    /// Forget the pass-through position, after it has been off for a while.
    func resetPassThrough() {
        passThrough.stop()
        passThroughScheduled = 0
        passThroughConverter.reset()
    }
}
