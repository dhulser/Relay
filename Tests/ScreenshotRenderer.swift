import XCTest
import SwiftUI
@testable import Relay

/// Renders the real views to PNGs for the marketing site, so what is shown is
/// the actual interface rather than a mockup that can drift from it.
///
/// Opt-in, since it writes into the repository. Gated on a marker file rather
/// than an environment variable, because xcodebuild runs tests in a separate
/// process that does not inherit the shell environment:
///     ./scripts/render-screenshots.sh
@MainActor
final class ScreenshotRenderer: XCTestCase {

    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("site/assets")
    }

    private func write<V: View>(_ view: V, to name: String, scale: CGFloat = 2) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw XCTSkip("could not render \(name)") }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try png.write(to: outputDirectory.appendingPathComponent(name))
    }

    /// Partial text goes through the subtitle debounce, so the run loop has to
    /// turn before it reaches the view.
    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testRenderSiteScreenshots() throws {
        let marker = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".render-screenshots")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: marker.path),
                          "Run ./scripts/render-screenshots.sh to regenerate site screenshots")

        // A conversation, mid-flow, with two speakers identified.
        let single = SubtitleStream(label: "Relay", tintIndex: 0)
        single.manager.complete("So I'll send the report over tomorrow morning,", speaker: 1)
        single.manager.complete("before anyone gets into the meeting.", speaker: 1)
        single.manager.updatePartial("That works — can we push it to Thursday?", speaker: 2)
        settle()
        try write(SubtitleView(streams: [single]), to: "subtitles.png")

        // Two engines racing on the same audio.
        let left = SubtitleStream(label: "Local · Claude", tintIndex: 0)
        left.manager.complete("I'll send the report over tomorrow morning.")
        left.manager.updatePartial("Before anyone gets into the meeting.")

        let right = SubtitleStream(label: "Realtime", tintIndex: 1)
        right.manager.complete("I'm going to send you the report tomorrow")
        right.manager.updatePartial("morning, before the meeting starts")
        settle()
        try write(SubtitleView(streams: [left, right], labelled: true), to: "comparison.png")

        // The popover, rebuilt from the same theme components. ImageRenderer
        // cannot rasterise AppKit-backed controls, so a live Picker comes out
        // as a placeholder; everything else here is the shipping view.
        try write(MenuBarPoster(), to: "menubar.png")
    }
}


/// A still of the menu bar popover for the site, using the real theme pieces
/// with the language menu drawn statically.
private struct MenuBarPoster: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RelayTheme.accent)
                Text("Relay")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
            }

            Divider().padding(.vertical, 12)

            RelayRow(label: "Translating to") {
                HStack(spacing: 5) {
                    Text("English")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )
            }

            Text("Detects the spoken language automatically.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 10)

            Spacer().frame(height: 16)

            Text("Start listening")
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: RelayTheme.cardCorner, style: .continuous)
                        .fill(RelayTheme.accent)
                )

            HStack(spacing: 7) {
                Circle()
                    .fill(RelayTheme.resting)
                    .frame(width: 7, height: 7)
                Text("Ready when you are")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 10)

            Divider().padding(.top, 14)

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                figure("4,182", "words")
                Spacer(minLength: 8)
                figure("3h 26m", "listening")
            }
            .padding(.top, 12)

            Text("French, Japanese and Spanish")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)

            Divider().padding(.vertical, 12)

            HStack(spacing: 14) {
                Text("Settings")
                Text("Recenter")
                Spacer()
                Text("Quit")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
        .background(Color(white: 0.99))
    }

    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(RelayTheme.accent)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}
