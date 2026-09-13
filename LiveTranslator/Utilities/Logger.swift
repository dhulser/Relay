import Foundation
import os

/// Console logging with stable `[Category] message` prefixes.
///
/// Everything goes to both stdout (visible when run from Xcode) and the unified
/// log (visible via `log stream --predicate 'subsystem == "co.kevel.LiveTranslator"'`,
/// which is how you watch a menu-bar app launched with `open`).
///
/// Never log the API key. Never log base64 audio payloads.
enum LogCategory: String {
    case app = "App"
    case audio = "Audio"
    case speech = "Speech"
    case whisper = "Whisper"
    case speakers = "Speakers"
    case openai = "OpenAI"
    case claude = "Claude"
    case realtime = "Realtime"
    case translation = "Translation"
    case subtitles = "Subtitles"
    case keychain = "Keychain"
}

enum Log {
    private static let subsystem = "co.kevel.LiveTranslator"
    private static var loggers: [String: os.Logger] = [:]
    private static let lock = NSLock()

    private static func logger(for category: LogCategory) -> os.Logger {
        lock.lock()
        defer { lock.unlock() }
        if let existing = loggers[category.rawValue] { return existing }
        let created = os.Logger(subsystem: subsystem, category: category.rawValue)
        loggers[category.rawValue] = created
        return created
    }

    static func info(_ category: LogCategory, _ message: String) {
        print("[\(category.rawValue)] \(message)")
        logger(for: category).log("\(message, privacy: .public)")
    }

    static func error(_ category: LogCategory, _ message: String) {
        print("[\(category.rawValue)] ERROR: \(message)")
        logger(for: category).error("\(message, privacy: .public)")
    }
}
