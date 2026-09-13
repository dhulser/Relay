import Foundation

/// Groups voiceprints into speakers as they arrive.
///
/// There is no enrolment and no idea who anyone is — the first voice heard
/// becomes Speaker 1, and later speech close enough to it is attributed there
/// too.
///
/// Measured cosine similarities, which is where every constant here comes from:
///
///   same voice, 2s+ clip      0.84 - 0.93
///   same voice, 0.4s clip     0.58
///   different but similar     0.33 - 0.44   (two female voices, same language)
///   different and dissimilar  0.06 - 0.16   (female vs male)
///
/// The similar-voice band is the one that matters: a threshold tuned on the
/// easy case merges two people who happen to sound alike. The threshold sits
/// above 0.44 and below 0.58, so it separates similar voices without splitting
/// one person across a short clip.
///
/// Clip length is handled separately. A short clip is still *matched* against
/// known speakers — that is reliable — but may not *create* one, since a low
/// score on half a second of audio says more about the clip than the speaker.
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
    ///     existing speaker. Sits between the 0.44 two similar voices reach and
    ///     the 0.58 one voice scores against itself on a short clip.
    ///   - stickiness: bonus given to whoever spoke last. Conversation comes in
    ///     runs, so a borderline clip belongs to the current speaker more often
    ///     than to a new one.
    ///   - maximum: hard cap on distinct speakers. Once reached, everything
    ///     joins its nearest match.
    init(threshold: Float = 0.55, stickiness: Float = 0.04, maximum: Int = 6) {
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
    ///
    /// - Parameter canCreateSpeaker: false for clips too short to trust as
    ///   evidence of someone new. Such a clip is still matched against known
    ///   speakers; it just cannot invent one.
    func assign(_ embedding: [Float], canCreateSpeaker: Bool = true) -> Int {
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

        let canAddSpeaker = canCreateSpeaker && speakers.count < maximum
        let isGenuineMatch = bestIndex >= 0 && bestScore >= threshold

        if isGenuineMatch || (bestIndex >= 0 && !canAddSpeaker) {
            var speaker = speakers[bestIndex]

            // Only learn from a real match. A clip that joined merely because
            // it wasn't allowed to create a speaker is a guess, and folding it
            // in would drag this centroid toward a voice that isn't this
            // speaker — which then swallows the real second speaker when they
            // do get a long enough clip.
            if isGenuineMatch {
                // Running mean keeps the centroid representative as more of a
                // person's speech arrives, rather than anchoring on their first
                // clip — which might have been half a word.
                let n = Float(speaker.count)
                speaker.centroid = Self.normalized(
                    zip(speaker.centroid, unit).map { ($0 * n + $1) / (n + 1) }
                )
                speaker.count += 1
                speakers[bestIndex] = speaker
            }

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
