import SwiftUI

/// The subtitle overlay's contents: recent finished lines above the one being
/// translated right now.
struct SubtitleView: View {
    @ObservedObject var manager: SubtitleManager

    /// Wide enough for a full sentence, narrow enough to stay readable.
    static let maximumWidth: CGFloat = 760

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(manager.history) { line in
                Text(line.text)
                    // Finished lines recede so the eye lands on the newest text.
                    .foregroundStyle(.white.opacity(0.55))
            }

            if !manager.current.isEmpty {
                Text(manager.current)
                    .foregroundStyle(.white)
            }
        }
        .font(.system(size: 26, weight: .medium, design: .rounded))
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: Self.maximumWidth, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.72))
        )
        // A soft shadow keeps the panel legible over light video content.
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .padding(10)   // room for the shadow inside the window
        .animation(.easeOut(duration: 0.12), value: manager.current)
        .animation(.easeOut(duration: 0.18), value: manager.history)
    }
}
