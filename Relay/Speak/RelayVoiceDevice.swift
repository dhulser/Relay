import Foundation
import AVFoundation
import CoreAudio

/// The virtual microphone, called **Relay Voice** in every app's device list.
///
/// It is an aggregate device whose only input is a process tap on Relay's own
/// playback. Whatever Relay plays while the device exists comes out of this
/// "microphone"; with `monitor == .silent` the tap also mutes that playback on
/// the real output, so the person at the Mac hears nothing and the call hears
/// everything. No driver, no installer, no new permission: the same two Core
/// Audio primitives `SystemAudioCaptureService` already uses, pointed the
/// other way.
///
/// The UID is fixed so a call app's remembered choice of microphone matches
/// again after Relay relaunches.
final class RelayVoiceDevice {

    static let uid = "co.kevel.Relay.voice"
    static let name = "Relay Voice"

    /// Whether the person at the Mac also hears what goes out.
    enum Monitor {
        /// `mutedWhenTapped`: the call hears it, the speakers do not.
        case silent
        /// Plain tap: speakers and call both hear it.
        case audible
    }

    enum DeviceError: LocalizedError {
        case noProcessObject
        case tapFailed(OSStatus)
        case aggregateFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noProcessObject:
                return "Relay has no audio process object yet; play something first."
            case .tapFailed(let status):
                return "Could not tap Relay's own audio (error \(status))."
            case .aggregateFailed(let status):
                return "Could not create the Relay Voice device (error \(status))."
            }
        }
    }

    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var deviceID = AudioObjectID(kAudioObjectUnknown)

    var exists: Bool { deviceID != kAudioObjectUnknown }

    /// Builds the tap and the device. Relay must already have played audio,
    /// because Core Audio only creates a process object for a process that
    /// has done IO; `ownProcessObject()` returns nil until then.
    func create(monitor: Monitor) throws {
        guard !exists else { return }
        guard let process = Self.ownProcessObject() else { throw DeviceError.noProcessObject }

        // A previous Relay that was killed rather than quit leaves its device
        // behind under the same UID, and a second create is refused. Take the
        // old one down first; its tap died with the process anyway.
        if let stale = Self.existingDevice() {
            let status = AudioHardwareDestroyAggregateDevice(stale)
            Log.info(.speak, "Removed a stale \(Self.name) device (\(stale), status \(status))")
        }

        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.uuid = UUID()
        description.name = "\(Self.name) tap"
        description.muteBehavior = monitor == .silent ? .mutedWhenTapped : .unmuted
        // Another process (the call app) reads this tap through the aggregate,
        // so it is not marked private the way the capture tap is.
        description.isPrivate = false

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            Log.error(.speak, "AudioHardwareCreateProcessTap failed (\(tapStatus))")
            throw DeviceError.tapFailed(tapStatus)
        }
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.name,
            kAudioAggregateDeviceUIDKey: Self.uid,
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard aggStatus == noErr, device != kAudioObjectUnknown else {
            Log.error(.speak, "AudioHardwareCreateAggregateDevice failed (\(aggStatus))")
            AudioHardwareDestroyProcessTap(tap)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw DeviceError.aggregateFailed(aggStatus)
        }
        deviceID = device
        Log.info(.speak, "\(Self.name) created (device \(device), tap \(tap), \(monitor == .silent ? "silent" : "audible") at the speakers)")
    }

    func destroy() {
        if deviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        Log.info(.speak, "\(Self.name) removed")
    }

    deinit { destroy() }

    /// True while some other process has IO running on the device: the
    /// closest Core Audio comes to "Zoom has picked Relay Voice".
    var isInUseByAnotherApp: Bool {
        guard exists else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// The device with our UID, if one already exists.
    static func existingDevice() -> AudioObjectID? {
        var uid = Self.uid as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// Core Audio's object for this process, or nil if it has never played.
    static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pid) { pidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<pid_t>.size), pidPointer, &size, &object)
        }
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }
}
