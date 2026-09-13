import Foundation

/// One finished line, as kept for an optional transcript.
struct TranscriptEntry: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let speaker: Int?
    let original: String?
    let translation: String
}

/// Plain-text rendering of a transcript. Deliberately simple: timestamps,
/// speaker labels when known, the original indented under the translation.
enum Transcript {

    static func text(for entries: [TranscriptEntry]) -> String {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"

        var lines: [String] = []
        for entry in entries {
            let who = entry.speaker.map { "Speaker \($0): " } ?? ""
            lines.append("[\(clock.string(from: entry.time))] \(who)\(entry.translation)")
            if let original = entry.original, !original.isEmpty, original != entry.translation {
                lines.append("    \(original)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func suggestedFileName(for entries: [TranscriptEntry]) -> String {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd HH.mm"
        let when = entries.first?.time ?? Date()
        return "Relay transcript \(day.string(from: when)).txt"
    }
}
