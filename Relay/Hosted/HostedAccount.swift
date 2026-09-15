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

    /// Whether signup is offered in Settings. Off until billing is live; an
    /// account that already exists keeps working either way.
    static let offered = false

    /// Where the Relay API lives.
    ///
    /// A `relayAPIBase` default overrides it, so a test build can point at a
    /// local `wrangler dev` or a staging Worker without a rebuild:
    ///   defaults write co.kevel.Relay relayAPIBase http://localhost:8787
    static let baseURL: URL = {
        if let override = UserDefaults.standard.string(forKey: "relayAPIBase"),
           let url = URL(string: override), url.scheme != nil {
            return url
        }
        return URL(string: productionBase)!
    }()

    private static let productionBase = "https://api.relay-9cf.workers.dev"
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
        struct Org: Decodable {
            let id: String
            let name: String
            let localModel: String
            /// Whether members may run a model other than the company's default.
            let allowModelChoice: Bool?
            let hasOpenAI: Bool
            let hasAnthropic: Bool
        }
        struct Member: Decodable { let email: String; let role: String }
        struct Policy: Decodable, Equatable {
            let allowInstant: Bool
            let allowTranscript: Bool
            let allowMicrophone: Bool
            static let everything = Policy(allowInstant: true, allowTranscript: true, allowMicrophone: true)
        }

        /// "customer" (individual, Stripe) or "member" (a company account).
        let kind: String?
        let org: Org?
        let member: Member?
        let policy: Policy?
        let reauthBy: Double?

        let status: String
        let month: String
        let localMinutes: Int
        let instantSeconds: Int
        let estimatedCents: Int
        let capCents: Int

        var isCompany: Bool { kind == "member" }

        var instantMinutes: Int { instantSeconds / 60 }
        var estimatedText: String { Self.dollars(estimatedCents) }
        var capText: String { Self.dollars(capCents) }
        static func dollars(_ cents: Int) -> String {
            cents % 100 == 0 ? "$\(cents / 100)" : String(format: "$%.2f", Double(cents) / 100)
        }
    }

    /// Hosted mode is in effect: signed in and switched on.
    var isActive: Bool { isSignedIn && enabled }

    /// A company account rather than an individual one. Remembered across
    /// launches so Settings reads right before the first refresh lands.
    @Published private(set) var companyName: String? {
        didSet { defaults.set(companyName, forKey: Self.companyKey) }
    }
    var isCompany: Bool { companyName != nil }
    var isCompanyAdmin: Bool { usage?.member?.role == "admin" }

    /// What the company allows. Everything, for individuals.
    @Published private(set) var policy: Usage.Policy = .everything

    /// What the company's admin settled on, remembered across launches so
    /// Settings reads correctly before the first refresh lands.
    @Published private(set) var allowsModelChoice: Bool {
        didSet { defaults.set(allowsModelChoice, forKey: Self.modelChoiceKey) }
    }
    @Published private(set) var orgModel: String? {
        didSet { defaults.set(orgModel, forKey: Self.orgModelKey) }
    }
    /// Which providers the company has given Relay a key for.
    @Published private(set) var orgProviders: Set<TranslationProvider> = [.openai, .openaiRealtime]

    /// The company's default model, named the way the app names models.
    var orgModelName: String {
        guard let orgModel else { return "the company default" }
        if let model = ClaudeModel(rawValue: orgModel) { return model.displayName }
        if let model = OpenAITextModel(rawValue: orgModel) { return model.displayName }
        return orgModel
    }

    private static let policyKey = "hostedPolicy"
    private static let companyKey = "hostedCompanyName"
    private static let modelChoiceKey = "hostedAllowsModelChoice"
    private static let orgModelKey = "hostedOrgModel"

    /// Sends the browser to the company's identity provider. The result comes
    /// back through relay://activate like everything else.
    func signInWithCompany(email: String) {
        var parts = URLComponents(url: Self.baseURL.appendingPathComponent("/auth/start"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "email", value: email.trimmingCharacters(in: .whitespaces)), URLQueryItem(name: "purpose", value: "app")]
        lastError = nil
        NSWorkspace.shared.open(parts.url!)
    }

    /// The admin console, for members who are admins.
    func openAdminConsole() {
        NSWorkspace.shared.open(Self.baseURL.appendingPathComponent("/admin"))
    }

    private func remember(_ usage: Usage) {
        companyName = usage.isCompany ? usage.org?.name : nil
        policy = usage.policy ?? .everything
        allowsModelChoice = usage.org?.allowModelChoice ?? false
        orgModel = usage.org?.localModel
        var providers: Set<TranslationProvider> = []
        if usage.org?.hasOpenAI == true { providers.formUnion([.openai, .openaiRealtime]) }
        if usage.org?.hasAnthropic == true { providers.insert(.claude) }
        orgProviders = providers.isEmpty ? [.openai, .openaiRealtime] : providers
        if let data = try? JSONEncoder().encode(["allowInstant": policy.allowInstant, "allowTranscript": policy.allowTranscript, "allowMicrophone": policy.allowMicrophone]) {
            defaults.set(data, forKey: Self.policyKey)
        }
    }

    private let defaults = UserDefaults.standard
    private static let enabledKey = "hostedEnabled"
    private static let keychainAccount = "relay-hosted-token"

    init() {
        isSignedIn = KeychainService.loadSecret(account: Self.keychainAccount) != nil
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        companyName = defaults.string(forKey: Self.companyKey)
        allowsModelChoice = defaults.bool(forKey: Self.modelChoiceKey)
        orgModel = defaults.string(forKey: Self.orgModelKey)
        if let data = defaults.data(forKey: Self.policyKey),
           let flags = try? JSONDecoder().decode([String: Bool].self, from: data) {
            policy = Usage.Policy(allowInstant: flags["allowInstant"] ?? true,
                                  allowTranscript: flags["allowTranscript"] ?? true,
                                  allowMicrophone: flags["allowMicrophone"] ?? true)
        }
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
            remember(usage)
            Log.info(.app, usage.isCompany ? "Signed in to \(usage.org?.name ?? "a company") account" : "Relay Hosted activated (\(usage.status))")
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Account

    func refreshUsage() async {
        guard let token else { return }
        do {
            let fresh: Usage = try await Self.call("GET", "/v1/me", token: token)
            usage = fresh
            remember(fresh)
            lastError = nil
        } catch let error as HostedError {
            // A revoked or expired sign-in: fall back to personal keys and say so.
            if case .message(let text) = error, text.contains("Sign in") {
                await signOut(quietly: true)
                lastError = isCompany ? "Your company sign-in has expired. Sign in again." : text
            } else {
                lastError = error.localizedDescription
            }
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

    func signOut(quietly: Bool = false) async {
        if let token, !quietly {
            _ = try? await Self.call("POST", "/v1/signout", token: token) as [String: Bool]
        }
        KeychainService.deleteSecret(account: Self.keychainAccount)
        isSignedIn = false
        usage = nil
        freshToken = nil
        companyName = nil
        policy = .everything
        allowsModelChoice = false
        orgModel = nil
        Log.info(.app, "Hosted account signed out")
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
