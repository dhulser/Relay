import AppKit
import Combine
import Sparkle

/// In-app updates via Sparkle. The appcast lives on the GitHub release, signed
/// with the EdDSA key whose public half is in Info.plist.
@MainActor
final class UpdaterService: ObservableObject {

    @Published private(set) var canCheck = false

    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheck)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var lastChecked: Date? { controller.updater.lastUpdateCheckDate }

    /// A menu-bar app has no window to attach the update sheet to, so it has
    /// to come forward first or the alert opens behind whatever is active.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Relay \(version) (\(build))"
    }
}
