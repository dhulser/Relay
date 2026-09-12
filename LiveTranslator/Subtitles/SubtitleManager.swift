import Foundation
import Combine

/// Buffers translation output so the overlay reads like captions rather than a
/// terminal printing tokens.
///
/// Text models emit deltas far faster than anyone can read — "I", "I'll",
/// "I'll send" — so partial updates are coalesced and published on a fixed
/// cadence instead of once per token. Completed utterances bypass the timer,
/// because a finished line should land immediately.
@MainActor
final class SubtitleManager: ObservableObject {

    struct Line: Identifiable, Equatable {
        let id = UUID()
        let text: String
        /// True when a noticeable silence preceded this line, which usually
        /// means a different speaker or a new thought. This is a pause, not an
        /// identity — none of the engines can tell us *who* is talking.
        let startsNewTurn: Bool
    }

    /// Finished lines, oldest first.
    @Published private(set) var history: [Line] = []

    /// The utterance being translated right now. Empty when nothing is in flight.
    @Published private(set) var current: String = ""

    /// Whether the in-flight utterance followed a noticeable pause.
    @Published private(set) var currentStartsNewTurn = false

    /// How often partial text may redraw. 150 ms is slow enough not to flicker,
    /// fast enough to feel live.
    private static let refreshInterval: TimeInterval = 0.15

    /// Completed lines kept on screen. Two plus the in-flight line gives the
    /// three visible rows the design asks for.
    private static let maxHistory = 2

    /// Wipe the overlay after this much silence so stale text doesn't sit
    /// there implying it's current.
    private static let idleClear: TimeInterval = 12

    /// Silence longer than this between utterances is treated as a turn
    /// change. Long enough to skip the natural gap between sentences from one
    /// speaker, short enough to catch a genuine hand-off.
    private static let turnGap: TimeInterval = 1.4

    private var lastCompletedAt = Date.distantPast
    private var currentStartedAt: Date?

    private var pending: String?
    private var flushWork: DispatchWorkItem?
    private var lastFlush = Date.distantPast
    private var idleTimer: Timer?

    var isEmpty: Bool { history.isEmpty && current.isEmpty }

    // MARK: - Input

    /// A revised guess at the utterance in flight. Coalesced.
    func updatePartial(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // The first fragment of an utterance marks when speech resumed, which
        // is what the turn gap is measured against.
        if current.isEmpty, currentStartedAt == nil {
            currentStartedAt = Date()
            currentStartsNewTurn = !history.isEmpty
                && Date().timeIntervalSince(lastCompletedAt) > Self.turnGap
        }

        pending = trimmed
        scheduleFlush()
        resetIdleTimer()
    }

    /// A finished utterance. Published immediately — waiting on the debounce
    /// timer would delay the one update that's guaranteed not to change.
    func complete(_ text: String) {
        cancelPendingFlush()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let startedAt = currentStartedAt ?? Date()
        let newTurn = !history.isEmpty && startedAt.timeIntervalSince(lastCompletedAt) > Self.turnGap

        current = ""
        currentStartsNewTurn = false
        currentStartedAt = nil
        lastCompletedAt = Date()

        guard !trimmed.isEmpty else { return }

        history.append(Line(text: trimmed, startsNewTurn: newTurn))
        if history.count > Self.maxHistory {
            history.removeFirst(history.count - Self.maxHistory)
        }
        Log.info(.subtitles, "line: \(trimmed)")
        resetIdleTimer()
    }

    func clear() {
        cancelPendingFlush()
        idleTimer?.invalidate()
        idleTimer = nil
        history.removeAll()
        current = ""
        currentStartsNewTurn = false
        currentStartedAt = nil
        lastCompletedAt = .distantPast
    }

    // MARK: - Debounce

    private func scheduleFlush() {
        guard flushWork == nil else { return }   // a flush is already queued

        let elapsed = Date().timeIntervalSince(lastFlush)
        guard elapsed < Self.refreshInterval else {
            flush()
            return
        }

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.refreshInterval - elapsed), execute: work)
    }

    private func flush() {
        flushWork = nil
        lastFlush = Date()
        guard let pending, pending != current else { return }
        current = pending
        self.pending = nil
    }

    private func cancelPendingFlush() {
        flushWork?.cancel()
        flushWork = nil
        pending = nil
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleClear, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.clear() }
        }
    }
}
