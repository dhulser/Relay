import Foundation

/// Groups voiceprints into speakers as they arrive.
///
/// There is no enrolment step and no idea who anyone is — the first voice heard
/// becomes Speaker 1, and any later utterance close enough to it is attributed
/// to Speaker 1 too. Measured separation on real speech is wide (same voice
/// ~0.85, different voices ~0.1), so the threshold sits in a large gap rather
/// than on a knife edge.
final class SpeakerClusterer {

    private struct Speaker {
        let id: Int
        var centroid: [Float]
        var count: Int
    }

    private var speakers: [Speaker] = []
    private let threshold: Float
    private let maximum: Int

    /// - Parameters:
    ///   - threshold: cosine similarity above which two clips are the same
    ///     voice. 0.5 sits roughly midway between the measured same-speaker and
    ///     different-speaker clusters.
    ///   - maximum: a cap so a noisy room can't spawn an endless speaker list.
    init(threshold: Float = 0.5, maximum: Int = 6) {
        self.threshold = threshold
        self.maximum = maximum
    }

    var knownSpeakers: Int { speakers.count }

    /// Returns the 1-based speaker number for this voiceprint.
    func assign(_ embedding: [Float]) -> Int {
        let unit = Self.normalized(embedding)
        guard !unit.isEmpty else { return 1 }

        var bestIndex = -1
        var bestScore: Float = -1
        for (index, speaker) in speakers.enumerated() {
            let score = Self.dot(unit, speaker.centroid)
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }

        if bestIndex >= 0, bestScore >= threshold {
            // Running mean keeps the centroid representative as more of a
            // person's speech arrives, rather than anchoring on their first
            // clip — which might have been half a word.
            var speaker = speakers[bestIndex]
            let n = Float(speaker.count)
            speaker.centroid = Self.normalized(
                zip(speaker.centroid, unit).map { ($0 * n + $1) / (n + 1) }
            )
            speaker.count += 1
            speakers[bestIndex] = speaker
            return speaker.id
        }

        guard speakers.count < maximum else {
            // Out of slots: attribute to the nearest rather than inventing a
            // speaker we'd never match again.
            return bestIndex >= 0 ? speakers[bestIndex].id : 1
        }

        let id = speakers.count + 1
        speakers.append(Speaker(id: id, centroid: unit, count: 1))
        Log.info(.speakers, "New voice → Speaker \(id)"
            + (bestIndex >= 0 ? String(format: " (closest existing %.2f)", bestScore) : ""))
        return id
    }

    func reset() {
        speakers.removeAll()
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
