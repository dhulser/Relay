import SwiftUI

/// The subtitle overlay: one stream normally, two side by side while comparing
/// engines so you can watch them race on the same audio.
struct SubtitleView: View {
    @ObservedObject var manager: SubtitleManager
    @ObservedObject var comparison: SubtitleManager

    /// When true, both columns are shown with engine headings.
    var comparing = false
    var primaryLabel = ""
    var rivalLabel = ""

    /// Reports the rendered height so the window can be sized around it.
    /// SwiftUI measures itself here rather than letting AppKit's Auto Layout
    /// drive the window, which would anchor growth to the top-left and walk the
    /// panel down the screen.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    /// Wide enough for a full sentence, narrow enough to stay readable.
    static let maximumWidth: CGFloat = 760
    /// Each column while comparing — narrower, since there are two.
    static let columnWidth: CGFloat = 430
    static let margin: CGFloat = 10

    static func contentWidth(comparing: Bool) -> CGFloat {
        comparing ? columnWidth * 2 + 28 : maximumWidth
    }

    /// One colour per speaker. Picked to stay legible on a dark, translucent
    /// panel over arbitrary video.
    static let speakerColours: [Color] = [
        Color(red: 0.51, green: 0.78, blue: 1.00),   // blue
        Color(red: 1.00, green: 0.76, blue: 0.44),   // amber
        Color(red: 0.62, green: 0.92, blue: 0.65),   // green
        Color(red: 1.00, green: 0.64, blue: 0.78),   // pink
        Color(red: 0.78, green: 0.72, blue: 1.00),   // violet
        Color(red: 0.60, green: 0.90, blue: 0.90),   // teal
    ]

    private static func colour(for speaker: Int) -> Color {
        speakerColours[(speaker - 1) % speakerColours.count]
    }

    private static let primaryTint = speakerColours[2]   // green
    private static let rivalTint = speakerColours[0]     // blue

    var body: some View {
        Group {
            if comparing { comparisonColumns } else { singleStream }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.72))
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .padding(Self.margin)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        .animation(.easeOut(duration: 0.12), value: manager.current)
        .animation(.easeOut(duration: 0.18), value: manager.history)
        .animation(.easeOut(duration: 0.12), value: comparison.current)
        .animation(.easeOut(duration: 0.18), value: comparison.history)
    }

    // MARK: - Normal

    private var singleStream: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(manager.history.enumerated()), id: \.element.id) { index, line in
                let previous = index > 0 ? manager.history[index - 1].speaker : nil
                if line.startsNewTurn && line.speaker == nil && index > 0 { turnDivider }
                speakerLabel(line.speaker, showing: line.speaker != nil && line.speaker != previous, dimmed: true)
                Text(line.text)
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundStyle(tint(line.speaker, dimmed: true))
            }

            if !manager.current.isEmpty {
                let previous = manager.history.last?.speaker
                if manager.currentStartsNewTurn && manager.currentSpeaker == nil && !manager.history.isEmpty { turnDivider }
                speakerLabel(manager.currentSpeaker,
                             showing: manager.currentSpeaker != nil && manager.currentSpeaker != previous,
                             dimmed: false)
                Text(manager.current)
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundStyle(tint(manager.currentSpeaker, dimmed: false))
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: Self.maximumWidth, alignment: .leading)
    }

    // MARK: - Comparing

    private var comparisonColumns: some View {
        HStack(alignment: .top, spacing: 0) {
            column(manager, title: primaryLabel, tint: Self.primaryTint)
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(width: 1)
                .padding(.horizontal, 13)
            column(comparison, title: rivalLabel, tint: Self.rivalTint)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func column(_ stream: SubtitleManager, title: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(tint.opacity(0.9))
                .padding(.bottom, 2)

            ForEach(stream.history) { line in
                Text(line.text)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(tint.opacity(0.55))
            }

            if !stream.current.isEmpty {
                Text(stream.current)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(tint)
            }

            // Keeps both columns the same height so neither jumps as the other
            // fills, which would make them hard to read against each other.
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
        .frame(width: Self.columnWidth, alignment: .topLeading)
    }

    // MARK: - Bits

    @ViewBuilder
    private func speakerLabel(_ speaker: Int?, showing: Bool, dimmed: Bool) -> some View {
        if showing, let speaker {
            Text("Speaker \(speaker)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Self.colour(for: speaker).opacity(dimmed ? 0.6 : 0.95))
                .padding(.top, 4)
        }
    }

    private func tint(_ speaker: Int?, dimmed: Bool) -> Color {
        if let speaker { return Self.colour(for: speaker).opacity(dimmed ? 0.55 : 1) }
        return .white.opacity(dimmed ? 0.55 : 1)
    }

    /// Marks a pause long enough to suggest a different speaker, used only when
    /// voiceprint labelling is off — we detect silence, not identity.
    private var turnDivider: some View {
        Capsule()
            .fill(.white.opacity(0.25))
            .frame(width: 48, height: 2)
            .padding(.vertical, 2)
    }
}
