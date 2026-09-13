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

    /// Words per language, so the totals can say what you actually listen to.
    @Published private(set) var wordsByLanguage: [String: Int]

    /// The best day so far. A record rather than a streak: something to notice,
    /// never something to keep up.
    @Published private(set) var bestDayWords: Int
    @Published private(set) var bestDayStamp: String

    /// A language heard for the first time, surfaced briefly and not stored.
    /// Small enough to be a pleasant surprise rather than an achievement.
    @Published private(set) var justDiscovered: String?

    private var todayWords: Int
    private var todayStamp: String

    /// Set while a session is running, so time is banked even if the app quits.
    private var startedAt: Date?

    private let defaults = UserDefaults.standard
    private static let wordsKey = "statsWords"
    private static let languagesKey = "statsLanguages"
    private static let secondsKey = "statsSeconds"
    private static let byLanguageKey = "statsWordsByLanguage"
    private static let bestWordsKey = "statsBestDayWords"
    private static let bestStampKey = "statsBestDayStamp"
    private static let todayWordsKey = "statsTodayWords"
    private static let todayStampKey = "statsTodayStamp"

    private static var stamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    init() {
        words = defaults.integer(forKey: Self.wordsKey)
        languages = Set(defaults.stringArray(forKey: Self.languagesKey) ?? [])
        seconds = defaults.double(forKey: Self.secondsKey)
        wordsByLanguage = defaults.dictionary(forKey: Self.byLanguageKey) as? [String: Int] ?? [:]
        bestDayWords = defaults.integer(forKey: Self.bestWordsKey)
        bestDayStamp = defaults.string(forKey: Self.bestStampKey) ?? ""
        todayWords = defaults.integer(forKey: Self.todayWordsKey)
        todayStamp = defaults.string(forKey: Self.todayStampKey) ?? Self.stamp
    }

    var hasAnything: Bool { words > 0 || seconds > 60 }

    // MARK: - Recording

    /// One finished line of translation, and the language it came from.
    func record(line: String, language code: String? = nil) {
        let count = line.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        guard count > 0 else { return }

        words += count
        defaults.set(words, forKey: Self.wordsKey)

        if let code, !code.isEmpty {
            wordsByLanguage[code, default: 0] += count
            defaults.set(wordsByLanguage, forKey: Self.byLanguageKey)
        }

        rollDayIfNeeded()
        todayWords += count
        defaults.set(todayWords, forKey: Self.todayWordsKey)

        // The record updates live, so a big day is visible while it happens
        // rather than only once midnight has passed.
        if todayWords > bestDayWords {
            bestDayWords = todayWords
            bestDayStamp = todayStamp
            defaults.set(bestDayWords, forKey: Self.bestWordsKey)
            defaults.set(bestDayStamp, forKey: Self.bestStampKey)
        }
    }

    /// Starts a fresh count when the date changes under a running session.
    private func rollDayIfNeeded() {
        let today = Self.stamp
        guard todayStamp != today else { return }
        todayStamp = today
        todayWords = 0
        defaults.set(todayStamp, forKey: Self.todayStampKey)
        defaults.set(todayWords, forKey: Self.todayWordsKey)
    }

    /// A language the recogniser identified. Realtime does not report one, so
    /// this only fills in on the local engines.
    func record(language code: String?) {
        guard let code, !code.isEmpty, !languages.contains(code) else { return }
        languages.insert(code)
        defaults.set(Array(languages), forKey: Self.languagesKey)

        if let name = Self.name(for: code) {
            justDiscovered = name
            Log.info(.app, "First time hearing \(name)")
        }
    }

    /// Clears the first-time note, once it has been seen.
    func acknowledgeDiscovery() {
        justDiscovered = nil
    }

    func beginSession() {
        startedAt = Date()
        justDiscovered = nil
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
        wordsByLanguage = [:]
        bestDayWords = 0
        bestDayStamp = ""
        todayWords = 0
        todayStamp = Self.stamp
        justDiscovered = nil
        startedAt = nil
        [Self.byLanguageKey, Self.bestWordsKey, Self.bestStampKey,
         Self.todayWordsKey, Self.todayStampKey].forEach(defaults.removeObject(forKey:))
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

    static func name(for code: String) -> String? {
        Language.allCases.first { $0.isoCode == code }?.displayName
    }

    /// Words per language, most heard first.
    var breakdown: [(language: String, words: Int)] {
        wordsByLanguage
            .compactMap { code, count in
                guard let name = Self.name(for: code) else { return nil }
                return (name, count)
            }
            .sorted { $0.1 > $1.1 }
    }

    /// "1,204 words on 3 Sep", or nil before there is a day worth naming.
    var bestDayText: String? {
        guard bestDayWords > 0, !bestDayStamp.isEmpty else { return nil }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"

        let when: String
        if let date = parser.date(from: bestDayStamp) {
            let pretty = DateFormatter()
            pretty.dateFormat = "d MMM"
            when = pretty.string(from: date)
        } else {
            when = bestDayStamp
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let count = formatter.string(from: NSNumber(value: bestDayWords)) ?? "\(bestDayWords)"
        return "\(count) words on \(when)"
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
