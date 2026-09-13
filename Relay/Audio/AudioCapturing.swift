import AppKit
import AVFoundation

/// Where Relay listens. Chosen in Settings; the default hears everything.
enum AudioSource: String, CaseIterable, Identifiable, Codable {
    /// Every sound the Mac plays.
    case systemAudio
    /// Only the apps the user ticked. Other audio never reaches Relay.
    case apps
    /// The microphone, for a conversation in the room.
    case microphone

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemAudio: return "Everything on this Mac"
        case .apps: return "Specific apps"
        case .microphone: return "Microphone"
        }
    }

    var detail: String {
        switch self {
        case .systemAudio:
            return "Whatever is coming out of your speakers: calls, videos, anything."
        case .apps:
            return "Only the apps you choose. A video in another window stays out of the subtitles. Open the app before you press start."
        case .microphone:
            return "For a conversation in the room. Relay asks for microphone permission the first time, and listens only while it is running."
        }
    }
}

/// Anything that can feed audio into the pipeline. Two live here: the system
/// tap and the microphone. Callbacks are delivered off the main thread, except
/// `onLevel` and `onError`, which arrive on main.
protocol AudioCapturing: AnyObject {
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func start() async throws
    func stop() async
}

/// A running app that could be listened to on its own.
struct ListenableApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let pid: pid_t
    var id: String { bundleID }

    /// Ordinary, windowed apps that are running right now. Helpers and
    /// background agents are left out; their audio is picked up through the
    /// app that owns them.
    @MainActor
    static var running: [ListenableApp] {
        var seen = Set<String>()
        var apps: [ListenableApp] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,
                  let name = app.localizedName,
                  seen.insert(bundleID).inserted
            else { continue }
            apps.append(ListenableApp(bundleID: bundleID, name: name, pid: app.processIdentifier))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
