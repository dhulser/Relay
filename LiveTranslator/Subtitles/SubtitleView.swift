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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(manager.history.enumerated()), id: \.element.id) { index, line in
                if line.startsNewTurn && index > 0 { turnDivider }
                Text(line.text)
                    // Finished lines recede so the eye lands on the newest text.
                    .foregroundStyle(.white.opacity(0.55))
            }

            if !manager.current.isEmpty {
                if manager.currentStartsNewTurn && !manager.history.isEmpty { turnDivider }
                Text(manager.current)
                    .foregroundStyle(.white)
            }
        }
        .font(.system(size: 26, weight: .medium, design: .rounded))
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

    /// Marks a pause long enough to suggest a different speaker. Deliberately a
    /// plain rule rather than a "Speaker 1" label — we detect silence, not
    /// identity, and a wrong name is worse than no name.
    private var turnDivider: some View {
        Capsule()
            .fill(.white.opacity(0.25))
            .frame(width: 48, height: 2)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}
