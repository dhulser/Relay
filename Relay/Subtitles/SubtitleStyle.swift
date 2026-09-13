import SwiftUI
import Combine

/// How the overlay looks. One shared instance, persisted, observed by the
/// subtitle view so a change in Settings shows up live on screen.
@MainActor
final class SubtitleStyle: ObservableObject {
    static let shared = SubtitleStyle()

    /// Point size of a caption line. 26 reads from across a desk.
    @Published var textSize: Double {
        didSet { defaults.set(textSize, forKey: Self.sizeKey) }
    }
    /// Opacity of the dark plate behind the words.
    @Published var plateOpacity: Double {
        didSet { defaults.set(plateOpacity, forKey: Self.opacityKey) }
    }
    /// Show what was heard, in small type, under each translated line.
    @Published var showOriginal: Bool {
        didSet { defaults.set(showOriginal, forKey: Self.originalKey) }
    }

    static let sizeRange: ClosedRange<Double> = 18...40
    static let opacityRange: ClosedRange<Double> = 0.35...0.95

    private let defaults = UserDefaults.standard
    private static let sizeKey = "subtitleTextSize"
    private static let opacityKey = "subtitlePlateOpacity"
    private static let originalKey = "subtitleShowOriginal"

    init() {
        let size = defaults.double(forKey: Self.sizeKey)
        textSize = size > 0 ? min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound) : 26
        let opacity = defaults.double(forKey: Self.opacityKey)
        plateOpacity = opacity > 0 ? min(max(opacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound) : 0.72
        showOriginal = defaults.bool(forKey: Self.originalKey)
    }

    /// Secondary type — labels, originals — scaled with the main size.
    var smallSize: Double { max(11, textSize * 0.5) }
    /// Column type while comparing.
    var columnSize: Double { max(13, textSize * 0.65) }

    func reset() {
        textSize = 26
        plateOpacity = 0.72
    }
}
