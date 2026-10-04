import AppKit
import SwiftUI

/// Always-on-top glass window with the standard macOS title bar buttons (close, minimize, zoom/tile),
/// floating over every Space and full-screen app.
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Voilà"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        // An empty unified toolbar makes the title bar 52pt tall, so the traffic lights
        // line up with our header row (and fit the 52pt compact pill).
        toolbar = NSToolbar(identifier: "VoilaToolbar")
        toolbarStyle = .unified
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the panel and handles show/hide and expanded ↔ compact resizing.
@MainActor
final class PanelController {
    static let expandedDefault = NSSize(width: 380, height: 600)
    static let compactSize = NSSize(width: 420, height: 52)

    let panel: FloatingPanel

    init<Content: View>(rootView: Content, compact: Bool) {
        let size = compact ? Self.compactSize : Self.savedExpandedSize
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size))
        // Host SwiftUI inside a plain container: as a window's direct contentView, NSHostingView
        // also drives the window frame, which can feed back into layout ("too many layout passes"
        // crash). Here only AppKit and setCompact(_:) change the window size.
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        // We lay out around the traffic lights ourselves; the title bar's safe-area inset (52pt)
        // would otherwise squeeze the 52pt compact pill.
        hosting.safeAreaRegions = []
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        applyLimits(compact: compact)
        // init(contentRect:) adds title bar height on top; force the exact frame size we want.
        panel.setFrame(NSRect(origin: .zero, size: size), display: false)

        if let origin = UserDefaults.standard.string(forKey: "panelTopLeft").map(NSPointFromString),
           NSScreen.screens.contains(where: { $0.frame.contains(origin) }) {
            panel.setFrameTopLeftPoint(origin)
        } else if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - size.width - 24, y: screen.maxY - 24))
        }

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveFrame() }
        }
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // willClose fires before the window is ordered out.
                    self.onVisibilityChange?(note.name == NSWindow.willCloseNotification ? false : self.isVisible)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: panel,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveFrame() }
        }
    }

    /// Called whenever the panel is shown, closed, minimized or restored.
    var onVisibilityChange: ((Bool) -> Void)?

    var isVisible: Bool { panel.isVisible && !panel.isMiniaturized }

    /// Width taken by the traffic lights, so content can start right after them.
    var trafficLightsInset: CGFloat {
        (panel.standardWindowButton(.zoomButton)?.frame.maxX ?? 64) + 12
    }

    func show() {
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        onVisibilityChange?(true)
    }

    func hide() { panel.performClose(nil) }
    func minimize() { panel.performMiniaturize(nil) }

    func setCompact(_ compact: Bool) {
        let top = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        if compact { saveFrame() }
        let size = compact ? Self.compactSize : Self.savedExpandedSize
        applyLimits(compact: compact)
        let frame = NSRect(x: top.x, y: top.y - size.height, width: size.width, height: size.height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func applyLimits(compact: Bool) {
        if compact {
            panel.minSize = Self.compactSize
            panel.maxSize = Self.compactSize
        } else {
            panel.minSize = NSSize(width: 320, height: 360)
            panel.maxSize = NSSize(width: 640, height: 1400)
        }
    }

    private static var savedExpandedSize: NSSize {
        UserDefaults.standard.string(forKey: "panelExpandedSize").map(NSSizeFromString)
            .flatMap { $0.width >= 320 && $0.height >= 360 ? $0 : nil } ?? expandedDefault
    }

    private func saveFrame() {
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: panel.frame.minX, y: panel.frame.maxY)),
                                  forKey: "panelTopLeft")
        if panel.frame.height > Self.compactSize.height + 10 {
            UserDefaults.standard.set(NSStringFromSize(panel.frame.size), forKey: "panelExpandedSize")
        }
    }
}

/// Lets the user drag the borderless panel from any SwiftUI area that hosts this view.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
