import AppKit
import SwiftUI
import Combine

/// The floating subtitle window.
///
/// `.nonactivatingPanel` plus `canBecomeKey == false` means clicking or
/// dragging it never pulls focus away from whatever you're watching. The window
/// level sits just above the menu bar, which is what keeps it visible over
/// full-screen apps without any private API — a CGS/SkyLight call would do the
/// same but can't ship.
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

/// Owns the subtitle panel: builds it lazily, keeps it sized to its content,
/// and remembers where the user dragged it.
@MainActor
final class SubtitlePanelController {

    private let manager: SubtitleManager
    private var panel: SubtitlePanel?
    private var hostingView: NSHostingView<SubtitleView>?
    private var cancellables: Set<AnyCancellable> = []
    private var moveObserver: NSObjectProtocol?

    private static let originKey = "subtitlePanelOrigin"
    /// Distance from the bottom of the screen when the user hasn't moved it.
    private static let defaultBottomInset: CGFloat = 120

    init(manager: SubtitleManager) {
        self.manager = manager
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    func show() {
        let panel = existingOrNewPanel()
        resizeToFit()
        panel.orderFrontRegardless()   // visible without activating the app
        Log.info(.subtitles, "Overlay shown")
    }

    func hide() {
        panel?.orderOut(nil)
        Log.info(.subtitles, "Overlay hidden")
    }

    // MARK: - Panel lifecycle

    private func existingOrNewPanel() -> SubtitlePanel {
        if let panel { return panel }

        let view = SubtitleView(manager: manager)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]

        let panel = SubtitlePanel(contentRect: NSRect(x: 0, y: 0, width: SubtitleView.maximumWidth, height: 90))
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting

        positionAtSavedOrDefaultOrigin(panel)
        observeContentChanges()
        observeUserDrags(panel)
        return panel
    }

    /// Resize whenever the text changes, so the box hugs its content instead of
    /// leaving a fixed-height slab on screen.
    private func observeContentChanges() {
        manager.$current
            .combineLatest(manager.$history)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.resizeToFit() }
            .store(in: &cancellables)
    }

    private func resizeToFit() {
        guard let panel, let hostingView else { return }

        let fitting = hostingView.fittingSize
        guard fitting.height > 0, fitting.width > 0 else { return }

        // Grow upward from the bottom-left corner so the panel stays anchored
        // where the user put it rather than drifting as lines are added.
        var frame = panel.frame
        let bottom = frame.minY
        frame.size = NSSize(width: min(fitting.width, SubtitleView.maximumWidth + 20),
                            height: fitting.height)
        frame.origin.y = bottom
        panel.setFrame(frame, display: true)
    }

    // MARK: - Position

    private func positionAtSavedOrDefaultOrigin(_ panel: SubtitlePanel) {
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let point = NSPointFromString(saved)
            // Only honour a saved spot that's still on an attached display —
            // otherwise unplugging a monitor strands the panel off-screen.
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(point) }) {
                panel.setFrameOrigin(point)
                return
            }
        }
        centerNearBottom(panel)
    }

    private func centerNearBottom(_ panel: SubtitlePanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + Self.defaultBottomInset
        )
        panel.setFrameOrigin(origin)
    }

    private func observeUserDrags(_ panel: SubtitlePanel) {
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { note in
            guard let moved = note.object as? NSPanel else { return }
            UserDefaults.standard.set(NSStringFromPoint(moved.frame.origin), forKey: Self.originKey)
        }
    }

    /// Puts the panel back at the bottom centre of the main display.
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.originKey)
        guard let panel else { return }
        centerNearBottom(panel)
    }
}
