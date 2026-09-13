import Foundation

/// One labelled stream of subtitles.
///
/// A normal session has a single stream. Comparison mode has one per engine,
/// each with its own history and debounce so a fast engine cannot scroll a slow
/// one away before it has been read.
@MainActor
final class SubtitleStream: Identifiable {
    let id = UUID()
    let label: String
    /// Index into the overlay's palette, so each engine keeps a stable colour.
    let tintIndex: Int
    let manager = SubtitleManager()

    init(label: String, tintIndex: Int) {
        self.label = label
        self.tintIndex = tintIndex
    }
}
