#if DEBUG
import Foundation
import AVFoundation
import Carbon
import AppKit

/// Throwaway: answers the two questions in docs/spoken-replies.md §11.
///
/// 1. Does a Relay Voice device built from a self-tap show up in call apps
///    and carry what Relay plays, with the speakers silent?
/// 2. Does the hold key report its release reliably?
///
/// Started from the popover footer in Debug builds, or by launching with
/// `--args -spikeVoice YES [-spikeMonitor audible]`. Plays the Cedar Spanish
/// sample from the voice test on a loop if it is on disk, otherwise a tone.
final class VoiceSpike {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var tone: AVAudioSourceNode?
    private let device = RelayVoiceDevice()
    private var holdKey: GlobalHotKey?
    private var pressedAt: Date?
    private var poll: Timer?
    private var lastInUse: Bool?
    private var file: AVAudioFile?

    private(set) var running = false

    func start(monitor: RelayVoiceDevice.Monitor) {
        guard !running else { return }
        running = true
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop()
        }
        Log.info(.speak, "Spike: starting (\(monitor == .silent ? "silent" : "audible"))")

        // Play first: Relay gets an audio process object only once it has
        // done IO, and the tap needs that object to exist.
        do {
            try startPlayback()
        } catch {
            Log.error(.speak, "Spike: playback failed: \(error.localizedDescription)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.running else { return }
            do {
                try self.device.create(monitor: monitor)
            } catch {
                Log.error(.speak, "Spike: \(error.localizedDescription)")
            }
        }

        // ⌃⌥Space, held.
        holdKey = GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey),
            onPress: { [weak self] in
                self?.pressedAt = Date()
                Log.info(.speak, "Spike: ⌃⌥Space pressed")
            },
            onRelease: { [weak self] in
                let held = self?.pressedAt.map { Date().timeIntervalSince($0) } ?? -1
                self?.pressedAt = nil
                Log.info(.speak, "Spike: ⌃⌥Space released after \(String(format: "%.2f", held)) s")
            })

        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let inUse = self.device.isInUseByAnotherApp
            if inUse != self.lastInUse {
                self.lastInUse = inUse
                Log.info(.speak, "Spike: \(RelayVoiceDevice.name) \(inUse ? "is being read by another app" : "is not in use by any app")")
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        poll?.invalidate(); poll = nil
        holdKey = nil
        device.destroy()
        player.stop()
        engine.stop()
        if let tone { engine.detach(tone); self.tone = nil }
        Log.info(.speak, "Spike: stopped")
    }

    // MARK: - Something to play

    private func startPlayback() throws {
        if let url = Self.sampleURL, let file = try? AVAudioFile(forReading: url) {
            self.file = file
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            try engine.start()
            scheduleLoop()
            player.play()
            Log.info(.speak, "Spike: looping \(url.lastPathComponent)")
        } else {
            let format = engine.outputNode.inputFormat(forBus: 0)
            var phase: Float = 0
            let step = Float(2 * Double.pi * 440 / format.sampleRate)
            let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for frame in 0..<Int(frameCount) {
                    let sample = sin(phase) * 0.2
                    phase += step
                    if phase > 2 * .pi { phase -= 2 * .pi }
                    for buffer in buffers {
                        buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                    }
                }
                return noErr
            }
            tone = node
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            try engine.start()
            Log.info(.speak, "Spike: playing a 440 Hz tone (no sample file found)")
        }
    }

    private func scheduleLoop() {
        guard let file, running else { return }
        player.scheduleFile(file, at: nil) { [weak self] in
            DispatchQueue.main.async { self?.scheduleLoop() }
        }
    }

    /// The Spanish Cedar sample from the voice test, if the test was run.
    private static var sampleURL: URL? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("build/voice-test/openai-es-m-cedar.m4a")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
#endif
