import SwiftUI

/// Shared visual language.
///
/// Deliberately soft: muted indigo rather than system blue, and status colours
/// that read as calm rather than alarming. A menu-bar utility sits next to the
/// system's own menus, so it should feel adjacent to macOS, not louder than it.
enum RelayTheme {
    static let accent = Color(red: 0.42, green: 0.45, blue: 0.86)
    static let accentSoft = Color(red: 0.42, green: 0.45, blue: 0.86).opacity(0.12)

    static let listening = Color(red: 0.30, green: 0.72, blue: 0.53)
    static let working = Color(red: 0.92, green: 0.68, blue: 0.35)
    static let attention = Color(red: 0.88, green: 0.47, blue: 0.45)
    static let resting = Color.secondary.opacity(0.55)

    static let cardCorner: CGFloat = 10
}

/// A quiet row: label on the left, control on the right.
struct RelayRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            content
        }
    }
}

/// The one prominent control in the popover.
struct RelayPrimaryButton: ButtonStyle {
    var running: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
            .foregroundStyle(running ? RelayTheme.attention : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: RelayTheme.cardCorner, style: .continuous)
                    .fill(running ? RelayTheme.attention.opacity(0.14) : RelayTheme.accent)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A status dot that breathes while listening, so "live" reads at a glance
/// without needing a spinner.
struct StatusDot: View {
    let colour: Color
    let pulsing: Bool
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: 7, height: 7)
            .overlay(
                Circle()
                    .stroke(colour.opacity(expanded ? 0 : 0.5), lineWidth: 3)
                    .scaleEffect(expanded ? 2.4 : 1)
            )
            .onAppear { if pulsing { start() } }
            .onChange(of: pulsing) { _, now in if now { start() } else { expanded = false } }
    }

    private func start() {
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            expanded = true
        }
    }
}
