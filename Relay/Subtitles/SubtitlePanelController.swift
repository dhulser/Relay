import AppKit
import SwiftUI
import Combine

/// The floating subtitle window.
///
/// `.nonactivatingPanel` plus `canBecomeKey == false` means clicking or
/// dragging it never pulls focus away from whatever you're watching. The window
/// level sits just above the menu bar, which is what keeps it visible over
/// full-screen apps without any private API.
final class SubtitlePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        isOpaque = false
        backgroundColor = .clear
        // The SwiftUI view draws its own shadow; the window's would double it.
        hasShadow = false
        // Unlike a pure HUD, this one is draggable, so it must receive clicks.
        isMovable = true
        isMovableByWindowBackground = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    /// Never take keyboard focus, even when clicked to drag.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The frame is computed from the screen rather than proposed by AppKit.
    /// Without this the window gets pushed back below the menu bar strip.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosts the SwiftUI subtitles and makes the whole surface a drag handle.
///
/// `isMovableByWindowBackground` alone does not work here: SwiftUI content
/// hit-tests opaquely, so `NSHostingView` swallows the mouse-down before the
/// window ever sees it. Forwarding to `performDrag` makes every part of the
/// caption draggable, text included.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    /// Show a grab cursor so it's discoverable that the panel can be moved.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

/// Owns the subtitle panel: sizes it to its content, keeps it anchored where
/// the user put it, and shows it only when there is something to read.
@MainActor
final class SubtitlePanelController {

    private var streams: [SubtitleStream] = []
    private var labelled = false
    private var panel: SubtitlePanel?
    private var cancellables: Set<AnyCancellable> = []
    private var moveObserver: NSObjectProtocol?

    /// The bottom-left corner the panel is pinned to. Everything is measured
    /// from here, so the window grows upward and never drifts. Only a user drag
    /// or a recenter changes it.
    private var anchor: NSPoint = .zero

    /// Whether a session is running. The panel is only on screen when this is
    /// true *and* there is text — an empty overlay is just a dark smudge.
    private var sessionActive = false

    private static let originKey = "subtitlePanelOrigin"
    private static let defaultBottomInset: CGFloat = 120

    init() {}

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    func show(streams: [SubtitleStream], labelled: Bool) {
        // Layouts of different column counts are different widths, so a panel
        // built for one cannot be reused for another.
        if streams.count != self.streams.count || labelled != self.labelled, panel != nil {
            panel?.orderOut(nil)
            panel = nil
            cancellables.removeAll()
            if let moveObserver {
                NotificationCenter.default.removeObserver(moveObserver)
                self.moveObserver = nil
            }
        }
        self.streams = streams
        self.labelled = labelled

        sessionActive = true
        _ = existingOrNewPanel()
        updateVisibility()
        Log.info(.subtitles, labelled ? "Overlay armed (\(streams.count) engines)" : "Overlay armed")
    }

    func hide() {
        sessionActive = false
        panel?.orderOut(nil)
        Log.info(.subtitles, "Overlay hidden")
    }

    // MARK: - Panel lifecycle

    @discardableResult
    private func existingOrNewPanel() -> SubtitlePanel {
        if let panel { return panel }

        let width = SubtitleView.contentWidth(columns: streams.count) + (SubtitleView.margin * 2) + 44
        let panel = SubtitlePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 80))

        // sizingOptions is deliberately empty: with .intrinsicContentSize the
        // hosting view installs constraints and AppKit resizes the window
        // itself, anchored top-left, which walks the panel down the screen as
        // lines are added. SwiftUI reports its height instead and we set the
        // frame ourselves.
        let hosting = DraggableHostingView(rootView: SubtitleView(
            streams: streams,
            labelled: labelled,
            onHeightChange: { [weak self] height in
                MainActor.assumeIsolated { self?.applyHeight(height) }
            }
        ))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 80)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
        loadAnchor(for: panel)
        observeContentChanges()
        observeUserDrags(panel)
        return panel
    }

    /// Resize around the anchor so the bottom edge stays put and the box grows
    /// upward, then keep the whole thing on an attached screen.
    private func applyHeight(_ height: CGFloat) {
        guard let panel, height > 1 else { return }

        var frame = panel.frame
        frame.size.height = height
        frame.origin = anchor
        panel.setFrame(clampedToScreen(frame), display: true)
    }

    private func clampedToScreen(_ frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }

        var clamped = frame
        clamped.origin.x = min(max(clamped.minX, visible.minX), visible.maxX - clamped.width)
        clamped.origin.y = min(max(clamped.minY, visible.minY), visible.maxY - clamped.height)
        return clamped
    }

    /// Show the panel only while a session is running and there is text.
    private func observeContentChanges() {
        for stream in streams {
            stream.manager.$current
                .combineLatest(stream.manager.$history)
                .receive(on: RunLoop.main)
                .sink { [weak self] _, _ in self?.updateVisibility() }
                .store(in: &cancellables)
        }
    }

    private func updateVisibility() {
        guard let panel else { return }
        let shouldShow = sessionActive && streams.contains { !$0.manager.isEmpty }

        if shouldShow, !panel.isVisible {
            panel.orderFrontRegardless()   // visible without activating the app
        } else if !shouldShow, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    // MARK: - Position

    private func loadAnchor(for panel: SubtitlePanel) {
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let point = NSPointFromString(saved)
            // Only honour a saved spot that's still on an attached display —
            // otherwise unplugging a monitor strands the panel off-screen.
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(point) }) {
                anchor = point
                panel.setFrameOrigin(point)
                return
            }
        }
        centerNearBottom(panel)
    }

    private func centerNearBottom(_ panel: SubtitlePanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        anchor = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + Self.defaultBottomInset
        )
        panel.setFrameOrigin(anchor)
    }

    private func observeUserDrags(_ panel: SubtitlePanel) {
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { note in
            guard let moved = note.object as? NSPanel else { return }
            MainActor.assumeIsolated {
                // Resizing sets the origin to the anchor already, so a frame
                // that still matches is our own move, not the user's.
                guard moved.frame.origin != self.anchor else { return }
                self.anchor = moved.frame.origin
                UserDefaults.standard.set(NSStringFromPoint(moved.frame.origin), forKey: Self.originKey)
                Log.info(.subtitles, "Overlay moved to \(Int(moved.frame.minX)),\(Int(moved.frame.minY))")
            }
        }
    }

    /// Puts the panel back at the bottom centre of the main display.
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.originKey)
        guard let panel else { return }
        centerNearBottom(panel)
        Log.info(.subtitles, "Overlay recentred")
    }
}
