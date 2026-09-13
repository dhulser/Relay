import AppKit
import Combine
import Foundation

/// Relay Hosted: Relay brings the keys, you pay $2 a month plus usage.
///
/// The account is a bearer token minted by the Relay API after a Stripe
/// checkout. It lives in the Keychain like the provider keys do. Everything
/// else about the account is looked up from the API when Settings needs it.
@MainActor
final class HostedAccount: ObservableObject {

    /// Where the Relay API lives. Filled in when the Worker was deployed.
    static let baseURL = URL(string: "https://relay-api.onethreefive.workers.dev")!
    /// The Instant-mode proxy; same host, WebSocket.
    static var realtimeEndpoint: URL {
        var parts = URLComponents(url: baseURL.appendingPathComponent("/v1/realtime"), resolvingAgainstBaseURL: false)!
        parts.scheme = "wss"
        return parts.url!
    }

    /// Whether a token is stored.
    @Published private(set) var isSignedIn: Bool
    /// The user can keep the account but switch back to their own keys.
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.enabledKey) }
    }
    @Published private(set) var usage: Usage?
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false

    /// A token minted for another Mac, shown once.
    @Published var freshToken: String?

    struct Usage: Decodable {
        let status: String
        let month: String
        let localMinutes: Int
        let instantSeconds: Int
        let estimatedCents: Int
        let capCents: Int

        var instantMinutes: Int { instantSeconds / 60 }
        var estimatedText: String { Self.dollars(estimatedCents) }
        var capText: String { Self.dollars(capCents) }
        static func dollars(_ cents: Int) -> String {
            cents % 100 == 0 ? "$\(cents / 100)" : String(format: "$%.2f", Double(cents) / 100)
        }
    }

    /// Hosted mode is in effect: signed in and switched on.
    var isActive: Bool { isSignedIn && enabled }

    private let defaults = UserDefaults.standard
    private static let enabledKey = "hostedEnabled"
    private static let keychainAccount = "relay-hosted-token"

    init() {
        isSignedIn = KeychainService.loadSecret(account: Self.keychainAccount) != nil
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    var token: String? { KeychainService.loadSecret(account: Self.keychainAccount) }

    // MARK: - Sign up and activate

    /// Opens Stripe Checkout in the browser. The success page hands the token
    /// back through the relay:// URL scheme, or as a code to paste.
    func beginCheckout() async {
        busy = true; defer { busy = false }
        lastError = nil
        do {
            let response: [String: String] = try await Self.call("POST", "/v1/checkout")
            guard let link = response["url"], let url = URL(string: link) else {
                throw HostedError.message("Stripe did not return a checkout link.")
            }
            NSWorkspace.shared.open(url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Stores a token and confirms it with the API.
    func activate(token raw: String) async {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("rly_"), token.count > 20 else {
            lastError = "That doesn't look like a Relay activation code."
            return
        }
        busy = true; defer { busy = false }
        lastError = nil
        do {
            let usage: Usage = try await Self.call("GET", "/v1/me", token: token)
            KeychainService.saveSecret(token, account: Self.keychainAccount)
            isSignedIn = true
            enabled = true
            self.usage = usage
            Log.info(.app, "Relay Hosted activated (\(usage.status))")
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Account

    func refreshUsage() async {
        guard let token else { return }
        do {
            usage = try await Self.call("GET", "/v1/me", token: token)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func openBilling() async {
        guard let token else { return }
        busy = true; defer { busy = false }
        do {
            let response: [String: String] = try await Self.call("POST", "/v1/portal", token: token)
            if let link = response["url"], let url = URL(string: link) { NSWorkspace.shared.open(url) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Mints a token for another Mac. Shown once; the API keeps only a hash.
    func mintTokenForAnotherMac() async {
        guard let token else { return }
        busy = true; defer { busy = false }
        do {
            let response: [String: String] = try await Self.call("POST", "/v1/tokens", token: token)
            freshToken = response["token"]
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() async {
        if let token {
            _ = try? await Self.call("POST", "/v1/signout", token: token) as [String: Bool]
        }
        KeychainService.deleteSecret(account: Self.keychainAccount)
        isSignedIn = false
        usage = nil
        freshToken = nil
        Log.info(.app, "Relay Hosted signed out")
    }

    // MARK: - HTTP

    enum HostedError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    private struct ErrorBody: Decodable { struct Inner: Decodable { let message: String }; let error: Inner }

    static func call<T: Decodable>(_ method: String, _ path: String, token: String? = nil) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
            throw HostedError.message(message ?? "Relay Hosted returned HTTP \(status).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
