import SwiftUI

/// The subtitle overlay: one stream normally, or one column per engine while
/// comparing, so you can watch them race on the same audio.
struct SubtitleView: View {
    let streams: [SubtitleStream]
    /// Show engine headings. Off for a single stream, where the heading would
    /// only state the obvious.
    var labelled = false

    /// Reports the rendered height so the window can be sized around it.
    /// SwiftUI measures itself here rather than letting AppKit's Auto Layout
    /// drive the window, which would anchor growth to the top-left and walk the
    /// panel down the screen.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    @ObservedObject private var style = SubtitleStyle.shared

    /// Wide enough for a full sentence, narrow enough to stay readable.
    static let maximumWidth: CGFloat = 760
    /// Each column while comparing — narrower, since there are several.
    static let columnWidth: CGFloat = 400
    static let margin: CGFloat = 10

    static func contentWidth(columns: Int) -> CGFloat {
        columns <= 1 ? maximumWidth : columnWidth * CGFloat(columns) + 28 * CGFloat(columns - 1)
    }

    /// One colour per engine, and per speaker. Picked to stay legible on a
    /// dark, translucent panel over arbitrary video.
    static let palette: [Color] = [
        Color(red: 0.62, green: 0.92, blue: 0.65),   // green
        Color(red: 0.51, green: 0.78, blue: 1.00),   // blue
        Color(red: 1.00, green: 0.76, blue: 0.44),   // amber
        Color(red: 1.00, green: 0.64, blue: 0.78),   // pink
        Color(red: 0.78, green: 0.72, blue: 1.00),   // violet
        Color(red: 0.60, green: 0.90, blue: 0.90),   // teal
    ]

    static func colour(at index: Int) -> Color { palette[index % palette.count] }

    init(streams: [SubtitleStream], labelled: Bool = false,
         onHeightChange: @escaping (CGFloat) -> Void = { _ in }) {
        self.streams = streams
        self.labelled = labelled
        self.onHeightChange = onHeightChange
    }

    var body: some View {
        Group {
            if streams.count <= 1, let only = streams.first {
                SingleStreamView(manager: only.manager)
                    .frame(width: Self.maximumWidth, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(streams.enumerated()), id: \.element.id) { index, stream in
                        if index > 0 {
                            Rectangle()
                                .fill(.white.opacity(0.12))
                                .frame(width: 1)
                                .padding(.horizontal, 13)
                        }
                        ColumnView(stream: stream, tint: Self.colour(at: stream.tintIndex))
                            .frame(width: Self.columnWidth, alignment: .topLeading)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(style.plateOpacity))
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .padding(Self.margin)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
    }
}

/// A normal session: large text, speaker labels, pause rules, and the
/// original words underneath when asked for.
private struct SingleStreamView: View {
    @ObservedObject var manager: SubtitleManager
    @ObservedObject private var style = SubtitleStyle.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let placeholder = manager.placeholder, manager.history.isEmpty, manager.current.isEmpty {
                Text(placeholder)
                    .font(.system(size: style.smallSize * 1.2, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            ForEach(Array(manager.history.enumerated()), id: \.element.id) { index, line in
                let previous = index > 0 ? manager.history[index - 1].speaker : nil
                if line.startsNewTurn && line.speaker == nil && index > 0 { turnDivider }
                label(line.speaker, showing: line.speaker != nil && line.speaker != previous, dimmed: true)
                Text(line.text)
                    .font(mainFont)
                    .foregroundStyle(tint(line.speaker, dimmed: true))
                if style.showOriginal, let original = line.original, original != line.text {
                    Text(original)
                        .font(smallFont)
                        .foregroundStyle(.white.opacity(0.38))
                }
            }

            if !manager.current.isEmpty || manager.currentOriginal != nil {
                let previous = manager.history.last?.speaker
                if manager.currentStartsNewTurn && manager.currentSpeaker == nil && !manager.history.isEmpty {
                    turnDivider
                }
                label(manager.currentSpeaker,
                      showing: manager.currentSpeaker != nil && manager.currentSpeaker != previous,
                      dimmed: false)
                if !manager.current.isEmpty {
                    Text(manager.current)
                        .font(mainFont)
                        .foregroundStyle(tint(manager.currentSpeaker, dimmed: false))
                }
                // The original lands before its translation, so for a moment
                // it is the only thing to show for this line.
                if style.showOriginal, let original = manager.currentOriginal {
                    Text(original)
                        .font(smallFont)
                        .foregroundStyle(.white.opacity(manager.current.isEmpty ? 0.7 : 0.5))
                }
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var mainFont: Font { .system(size: style.textSize, weight: .medium, design: .rounded) }
    private var smallFont: Font { .system(size: style.smallSize, weight: .medium, design: .rounded) }

    @ViewBuilder
    private func label(_ speaker: Int?, showing: Bool, dimmed: Bool) -> some View {
        if showing, let speaker {
            Text("Speaker \(speaker)")
                .font(.system(size: max(11, style.textSize * 0.5), weight: .semibold, design: .rounded))
                .foregroundStyle(SubtitleView.colour(at: speaker - 1).opacity(dimmed ? 0.6 : 0.95))
                .padding(.top, 4)
        }
    }

    private func tint(_ speaker: Int?, dimmed: Bool) -> Color {
        if let speaker { return SubtitleView.colour(at: speaker - 1).opacity(dimmed ? 0.55 : 1) }
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

/// One engine's column while comparing.
private struct ColumnView: View {
    let stream: SubtitleStream
    let tint: Color
    @ObservedObject private var manager: SubtitleManager
    @ObservedObject private var style = SubtitleStyle.shared

    init(stream: SubtitleStream, tint: Color) {
        self.stream = stream
        self.tint = tint
        self.manager = stream.manager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(stream.label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(tint.opacity(0.9))
                .padding(.bottom, 2)

            if let placeholder = manager.placeholder, manager.history.isEmpty, manager.current.isEmpty {
                Text(placeholder)
                    .font(.system(size: style.columnSize * 0.8, weight: .medium, design: .rounded))
                    .foregroundStyle(tint.opacity(0.5))
            }
            ForEach(manager.history) { line in
                Text(line.text)
                    .font(.system(size: style.columnSize, weight: .medium, design: .rounded))
                    .foregroundStyle(tint.opacity(0.55))
            }

            if !manager.current.isEmpty {
                Text(manager.current)
                    .font(.system(size: style.columnSize, weight: .medium, design: .rounded))
                    .foregroundStyle(tint)
            }

            // Keeps columns the same height so none jumps as another fills,
            // which would make them hard to read against each other.
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
    }
}
