import Foundation
import Combine

/// A running tally of what Relay has translated for you.
///
/// Counts only: how many words, which languages were heard, how long it ran.
/// No text is ever stored, which keeps the promise that Relay holds on to
/// nothing you said. The numbers survive relaunches and can be reset.
@MainActor
final class TranslationStats: ObservableObject {

    @Published private(set) var words: Int
    /// ISO-639-1 codes, recorded when the recogniser can tell us what it heard.
    @Published private(set) var languages: Set<String>
    @Published private(set) var seconds: TimeInterval

    /// Set while a session is running, so time is banked even if the app quits.
    private var startedAt: Date?

    private let defaults = UserDefaults.standard
    private static let wordsKey = "statsWords"
    private static let languagesKey = "statsLanguages"
    private static let secondsKey = "statsSeconds"

    init() {
        words = defaults.integer(forKey: Self.wordsKey)
        languages = Set(defaults.stringArray(forKey: Self.languagesKey) ?? [])
        seconds = defaults.double(forKey: Self.secondsKey)
    }

    var hasAnything: Bool { words > 0 || seconds > 60 }

    // MARK: - Recording

    /// One finished line of translation.
    func record(line: String) {
        let count = line.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        guard count > 0 else { return }
        words += count
        defaults.set(words, forKey: Self.wordsKey)
    }

    /// A language the recogniser identified. Realtime does not report one, so
    /// this only fills in on the local engines.
    func record(language code: String?) {
        guard let code, !code.isEmpty, !languages.contains(code) else { return }
        languages.insert(code)
        defaults.set(Array(languages), forKey: Self.languagesKey)
    }

    func beginSession() {
        startedAt = Date()
    }

    func endSession() {
        guard let startedAt else { return }
        seconds += Date().timeIntervalSince(startedAt)
        defaults.set(seconds, forKey: Self.secondsKey)
        self.startedAt = nil
    }

    func reset() {
        words = 0
        languages = []
        seconds = 0
        startedAt = nil
        defaults.removeObject(forKey: Self.wordsKey)
        defaults.removeObject(forKey: Self.languagesKey)
        defaults.removeObject(forKey: Self.secondsKey)
    }

    // MARK: - Display

    var wordsText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: words)) ?? "\(words)"
    }

    /// Language names read better than a count: "Spanish and French" tells you
    /// something, "2 languages" does not.
    var languagesText: String? {
        let resolved = languages
            .compactMap { code in Language.allCases.first { $0.isoCode == code }?.displayName }
            .sorted()

        switch resolved.count {
        case 0: return nil
        case 1: return resolved[0]
        case 2: return "\(resolved[0]) and \(resolved[1])"
        case 3: return "\(resolved[0]), \(resolved[1]) and \(resolved[2])"
        default: return "\(resolved[0]), \(resolved[1]) and \(resolved.count - 2) more"
        }
    }

    var listeningText: String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "under a minute"
    }
}
