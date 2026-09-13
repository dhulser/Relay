import Foundation
import AppKit
import AVFoundation
import CoreAudio

enum CaptureError: LocalizedError {
    case permissionDenied
    case tapFailed(OSStatus)
    case deviceFailed(OSStatus)
    case unsupportedFormat
    /// The user chose specific apps and none of them is running.
    case noChosenAppRunning
    /// The microphone source was chosen and permission was refused.
    case microphoneDenied
    /// macOS ended the capture on the user's behalf. A deliberate stop, not a
    /// failure.
    case stoppedExternally

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Relay needs permission to hear your Mac's audio."
        case .tapFailed(let status):
            return "Could not listen to system audio (error \(status))."
        case .deviceFailed(let status):
            return "Could not open the audio device (error \(status))."
        case .unsupportedFormat:
            return "The system audio format could not be read."
        case .noChosenAppRunning:
            return "None of the apps you chose is open. Open one, then press start again."
        case .microphoneDenied:
            return "Relay needs permission to use your microphone."
        case .stoppedExternally:
            return "Audio capture was stopped."
        }
    }
}

/// Captures system audio with a Core Audio process tap.
///
/// The obvious way to do this used to be ScreenCaptureKit, which works but asks
/// for Screen Recording permission and makes macOS show the screen-sharing
/// indicator, telling the user their screen is being shared when only their
/// audio is being read. A process tap (macOS 14.2+) captures audio and nothing
/// else, so neither of those is true any more.
///
/// Nothing is written to disk; buffers live only long enough to hand off.
final class SystemAudioCaptureService: AudioCapturing {

    /// What the tap covers. Set before `start()`.
    enum Scope {
        case everything
        /// Process IDs of the apps to hear. Helper processes those apps own
        /// are included, since that is where browsers and Zoom actually
        /// play their audio.
        case apps([pid_t])
    }
    var scope: Scope = .everything

    /// Audio in whatever format the tap provides. Delivered on the capture
    /// queue, never on main.
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// 0…1 RMS level, delivered on the main queue for the UI meter.
    var onLevel: ((Float) -> Void)?

    /// Fatal capture problems. Delivered on the main queue.
    var onError: ((Error) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?

    private let captureQueue = DispatchQueue(label: "co.kevel.Relay.audio", qos: .userInitiated)

    // Diagnostics
    private var loggedFormat = false
    private var buffersSeen = 0
    private var levelPeak: Float = 0
    private var lastLevelReport = Date.distantPast

    static func openAudioSettings() {
        // System audio capture lives under "Screen & System Audio Recording",
        // not Microphone. Privacy_AudioCapture is the anchor for that pane.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Lifecycle

    func start() async throws {
        try createTap()
        try createAggregateDevice()
        try startIO()

        loggedFormat = false
        buffersSeen = 0
        levelPeak = 0
        lastLevelReport = .distantPast
        Log.info(.audio, "Capture started")
    }

    func stop() async {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        format = nil
        Log.info(.audio, "Capture stopped")
    }

    // MARK: - Building the tap

    private func createTap() throws {
        let description: CATapDescription
        switch scope {
        case .everything:
            // Relay plays no audio of its own, so there is nothing to exclude
            // and a global tap picks up everything the Mac is playing.
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .apps(let pids):
            let objects = Self.audioProcessObjects(belongingTo: pids)
            guard !objects.isEmpty else { throw CaptureError.noChosenAppRunning }
            Log.info(.audio, "Tapping \(objects.count) audio process(es) for \(pids.count) chosen app(s)")
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        }
        description.uuid = UUID()
        description.name = "Relay"
        // muteBehavior is left at its default, CATapUnmuted. Leaving playback
        // audible is the whole point: you keep hearing the call.
        description.isPrivate = true

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            // A refused tap is almost always a missing permission rather than a
            // broken device.
            Log.error(.audio, "AudioHardwareCreateProcessTap failed (\(status))")
            throw status == kAudioHardwareIllegalOperationError
                ? CaptureError.permissionDenied
                : CaptureError.tapFailed(status)
        }
        tapID = id
        self.format = try tapFormat(of: id)
    }

    private func tapFormat(of tap: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = AudioStreamBasicDescription()
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError.unsupportedFormat
        }
        return format
    }

    /// The tap is only readable through a device, so it goes into a private
    /// aggregate that nothing else sees.
    private func createAggregateDevice() throws {
        guard tapID != kAudioObjectUnknown else { throw CaptureError.tapFailed(-1) }

        let tapUID = (try? tapUUID(of: tapID)) ?? UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Relay Audio",
            kAudioAggregateDeviceUIDKey: "co.kevel.Relay.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            Log.error(.audio, "AudioHardwareCreateAggregateDevice failed (\(status))")
            throw CaptureError.deviceFailed(status)
        }
        aggregateID = id
    }

    private func tapUUID(of tap: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString? = nil
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(tap, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let uid = uid as String? else { throw CaptureError.tapFailed(status) }
        return uid
    }

    private func startIO() throws {
        guard let format else { throw CaptureError.unsupportedFormat }

        var id: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&id, aggregateID, captureQueue) {
            [weak self] _, inputData, _, _, _ in
            self?.handle(inputData, format: format)
        }
        guard status == noErr, let id else {
            Log.error(.audio, "AudioDeviceCreateIOProcIDWithBlock failed (\(status))")
            throw CaptureError.deviceFailed(status)
        }
        procID = id

        let started = AudioDeviceStart(aggregateID, id)
        guard started == noErr else {
            Log.error(.audio, "AudioDeviceStart failed (\(started))")
            throw CaptureError.deviceFailed(started)
        }
    }

    // MARK: - Per-app scope

    /// Every Core Audio process object whose process is one of `pids` or a
    /// descendant of one. Chrome plays through a helper, Zoom through
    /// CptHost; matching on ancestry catches both without a list of names.
    static func audioProcessObjects(belongingTo pids: [pid_t]) -> [AudioObjectID] {
        let chosen = Set(pids)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        return objects.filter { object in
            guard let pid = processID(of: object) else { return false }
            var current = pid
            for _ in 0..<6 {
                if chosen.contains(current) { return true }
                guard let parent = parentProcessID(of: current), parent > 1 else { return false }
                current = parent
            }
            return false
        }
    }

    private static func processID(of object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    private static func parentProcessID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    // MARK: - Audio in

    private func handle(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list) else { return }
        guard buffer.frameLength > 0 else { return }

        if !loggedFormat {
            loggedFormat = true
            let channels = format.channelCount == 1 ? "mono" : "\(format.channelCount)ch"
            Log.info(.audio, "Input: \(Int(format.sampleRate)) Hz \(channels), "
                + "\(format.commonFormat == .pcmFormatFloat32 ? "Float32" : "other")")
        }

        buffersSeen += 1
        if buffersSeen <= 3 {
            let ms = Double(buffer.frameLength) / format.sampleRate * 1000
            Log.info(.audio, "Buffer \(buffersSeen): \(buffer.frameLength) frames "
                + "(\(String(format: "%.1f", ms)) ms)")
        }

        reportLevel(for: buffer)
        onAudioBuffer?(buffer)
    }

    private func reportLevel(for buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        var sum: Float = 0
        for channel in 0..<channelCount {
            let data = channels[channel]
            for frame in 0..<frames { sum += data[frame] * data[frame] }
        }
        let rms = (sum / Float(max(frames * channelCount, 1))).squareRoot()

        levelPeak = max(levelPeak, rms)

        // The meter only needs a couple of updates a second.
        let now = Date()
        guard now.timeIntervalSince(lastLevelReport) >= 0.5 else { return }
        lastLevelReport = now

        let peak = levelPeak
        levelPeak = 0
        DispatchQueue.main.async { [weak self] in self?.onLevel?(peak) }
    }
}
