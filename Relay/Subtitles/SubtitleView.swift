import SwiftUI

/// The subtitle overlay's contents: recent finished lines above the one being
/// translated right now.
struct SubtitleView: View {
    @ObservedObject var manager: SubtitleManager

    /// Reports the rendered height so the window can be sized around it.
    /// SwiftUI measures itself here rather than letting AppKit's Auto Layout
    /// drive the window, which would anchor growth to the top-left and walk the
    /// panel down the screen.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    /// Wide enough for a full sentence, narrow enough to stay readable.
    static let maximumWidth: CGFloat = 760
    /// Padding around the box, leaving room for its shadow.
    static let margin: CGFloat = 10

    /// One colour per speaker. Picked to stay legible on a dark, translucent
    /// panel over arbitrary video.
    private static let speakerColours: [Color] = [
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(manager.history.enumerated()), id: \.element.id) { index, line in
                let previous = index > 0 ? manager.history[index - 1].speaker : nil
                row(text: line.text,
                    speaker: line.speaker,
                    showsLabel: line.speaker != nil && line.speaker != previous,
                    // With real speaker labels the pause rule is redundant.
                    showsDivider: line.speaker == nil && line.startsNewTurn && index > 0,
                    dimmed: true)
            }

            if !manager.current.isEmpty {
                let previous = manager.history.last?.speaker
                row(text: manager.current,
                    speaker: manager.currentSpeaker,
                    showsLabel: manager.currentSpeaker != nil && manager.currentSpeaker != previous,
                    showsDivider: manager.currentSpeaker == nil
                        && manager.currentStartsNewTurn && !manager.history.isEmpty,
                    dimmed: false)
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: Self.maximumWidth, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.72))
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .padding(Self.margin)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onHeightChange(height)
        }
        .animation(.easeOut(duration: 0.12), value: manager.current)
        .animation(.easeOut(duration: 0.18), value: manager.history)
    }

    @ViewBuilder
    private func row(text: String, speaker: Int?, showsLabel: Bool,
                     showsDivider: Bool, dimmed: Bool) -> some View {
        if showsDivider { turnDivider }

        VStack(alignment: .leading, spacing: 2) {
            if showsLabel, let speaker {
                Text("Speaker \(speaker)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Self.colour(for: speaker).opacity(dimmed ? 0.6 : 0.95))
                    .padding(.top, 4)
            }

            Text(text)
                .font(.system(size: 26, weight: .medium, design: .rounded))
                // Finished lines recede so the eye lands on the newest text;
                // a speaker's colour tints their line so turns read at a glance.
                .foregroundStyle(speaker.map {
                    Self.colour(for: $0).opacity(dimmed ? 0.55 : 1)
                } ?? .white.opacity(dimmed ? 0.55 : 1))
        }
    }

    /// Marks a pause long enough to suggest a different speaker, used only when
    /// voiceprint labelling is off — we detect silence, not identity.
    private var turnDivider: some View {
        Capsule()
            .fill(.white.opacity(0.25))
            .frame(width: 48, height: 2)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}
