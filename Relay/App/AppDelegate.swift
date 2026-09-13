import AppKit

/// Receives relay:// links. The one we use is relay://activate?token=…, sent
/// by the Relay Hosted success page after checkout.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let activationNotification = Notification.Name("co.kevel.Relay.activate")

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "relay" && url.host == "activate" {
            let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "token" }?.value
            guard let token else { continue }
            NotificationCenter.default.post(name: Self.activationNotification, object: nil, userInfo: ["token": token])
        }
    }
}
