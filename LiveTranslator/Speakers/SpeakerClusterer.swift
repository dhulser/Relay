import Foundation

/// Groups voiceprints into speakers as they arrive.
///
/// There is no enrolment and no idea who anyone is — the first voice heard
/// becomes Speaker 1, and later speech close enough to it is attributed there
/// too.
///
/// The design is deliberately biased against inventing speakers. Measured on
/// real clips, a *different* voice scores ~0.1 no matter how little audio there
/// is, while the *same* voice drops from ~0.91 to ~0.58 as the clip shortens
/// from 4s to 0.4s. So a low score means "not enough audio" far more often than
/// it means "somebody new", and treating every low score as a new person is
/// what splits two people into five.
final class SpeakerClusterer {

    private struct Speaker {
        let id: Int
        var centroid: [Float]
        var count: Int
    }

    private var speakers: [Speaker] = []
    private let threshold: Float
    private let stickiness: Float
    private var maximum: Int

    /// Who spoke last. Short clips inherit this rather than being guessed at.
    private(set) var lastAssigned: Int?

    /// - Parameters:
    ///   - threshold: cosine similarity above which a voiceprint joins an
    ///     existing speaker. Well above the ~0.16 a different voice scores, and
    ///     well below the ~0.85 the same voice scores on a decent clip.
    ///   - stickiness: bonus given to whoever spoke last. Conversation comes in
    ///     runs, so a borderline clip belongs to the current speaker more often
    ///     than to a new one.
    ///   - maximum: hard cap on distinct speakers. Once reached, everything
    ///     joins its nearest match.
    init(threshold: Float = 0.35, stickiness: Float = 0.06, maximum: Int = 6) {
        self.threshold = threshold
        self.stickiness = stickiness
        self.maximum = maximum
    }

    var knownSpeakers: Int { speakers.count }

    /// Lower the cap when the user knows how many people are talking. Existing
    /// speakers beyond the new cap are left alone; only new ones are refused.
    func setMaximum(_ value: Int) {
        maximum = max(1, value)
    }

    /// Returns the 1-based speaker number for this voiceprint.
    func assign(_ embedding: [Float]) -> Int {
        let unit = Self.normalized(embedding)
        guard !unit.isEmpty else { return lastAssigned ?? 1 }

        var bestIndex = -1
        var bestScore: Float = -1
        for (index, speaker) in speakers.enumerated() {
            var score = Self.dot(unit, speaker.centroid)
            if speaker.id == lastAssigned { score += stickiness }
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }

        let canAddSpeaker = speakers.count < maximum
        if bestIndex >= 0, bestScore >= threshold || !canAddSpeaker {
            var speaker = speakers[bestIndex]
            // Running mean keeps the centroid representative as more of a
            // person's speech arrives, rather than anchoring on their first
            // clip — which might have been half a word.
            let n = Float(speaker.count)
            speaker.centroid = Self.normalized(
                zip(speaker.centroid, unit).map { ($0 * n + $1) / (n + 1) }
            )
            speaker.count += 1
            speakers[bestIndex] = speaker
            lastAssigned = speaker.id
            return speaker.id
        }

        let id = speakers.count + 1
        speakers.append(Speaker(id: id, centroid: unit, count: 1))
        lastAssigned = id
        Log.info(.speakers, "New voice → Speaker \(id)"
            + (bestIndex >= 0 ? String(format: " (closest existing %.2f)", bestScore) : ""))
        return id
    }

    /// For clips too short to embed reliably: stay with whoever was talking.
    func inheritLastSpeaker() -> Int? { lastAssigned }

    func reset() {
        speakers.removeAll()
        lastAssigned = nil
    }

    // MARK: - Vector maths

    private static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        guard norm > 1e-9 else { return v }
        return v.map { $0 / norm }
    }

    /// Both inputs are unit vectors, so the dot product is the cosine.
    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var total: Float = 0
        for i in 0..<min(a.count, b.count) { total += a[i] * b[i] }
        return total
    }
}
