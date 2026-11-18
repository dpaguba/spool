import AppKit
import SwiftUI

/// The borderless glass panel under the menu bar item. It closes on a second click on the
/// item, `Esc`, a click outside, and when it stops being the key window.
@MainActor final class PanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let openSettings: () -> Void

    private let panel: SpoolPanel
    private let glass = NSGlassEffectView()
    private var hostingView: PanelHostingView?
    private weak var anchor: NSStatusBarButton?
    private var monitors: [Any] = []

    private static let width: CGFloat = 300
    /// Corner radius of the glass and of the shape the window server draws the shadow from.
    fileprivate static let cornerRadius: CGFloat = 16
    /// Gap between the menu bar and the panel's top edge.
    private static let gap: CGFloat = 4
    /// Minimum distance to the screen's side edges.
    private static let margin: CGFloat = 8
    /// A status button whose centre lies this close to the screen top is in the menu bar.
    private static let menuBarBand: CGFloat = 50

    init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        panel = SpoolPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: true)
        super.init()
        // No `isFloatingPanel`: setting it resets the level to `.floating`.
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        glass.cornerRadius = Self.cornerRadius
        panel.contentView = glass
    }

    var isOpen: Bool { panel.isVisible }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isOpen { close() } else { open(relativeTo: button) }
    }

    func close() {
        guard panel.isVisible else { return }
        removeMonitors()
        panel.orderOut(nil)
        // Drop the SwiftUI tree so nothing updates while the panel is hidden; the next open
        // starts with a fresh provider selection.
        glass.contentView = nil
        hostingView = nil
    }

    // MARK: - Opening

    private func open(relativeTo button: NSStatusBarButton) {
        anchor = button
        model.reload(checkConnection: true)
        // Enabled optional sources only, each through its gate; new data redraws the panel.
        model.checkSources()

        let view = PanelView(model: model, openSettings: { [weak self] in
            // Hop out of the menu action before the panel drops its SwiftUI tree.
            Task { @MainActor in
                self?.close()
                self?.openSettings()
            }
        })
        let hosting = PanelHostingView(rootView: view)
        hosting.onIntrinsicSizeChange = { [weak self] in
            // Resize after SwiftUI finishes the current update, not inside it.
            Task { @MainActor in self?.fitToContent() }
        }
        hostingView = hosting
        glass.contentView = hosting
        fitToContent()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        panel.makeKey()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
        installMonitors()
    }

    /// Sizes the panel to its SwiftUI content and places it under the status button, keeping
    /// it on screen.
    private func fitToContent() {
        guard let hostingView else { return }
        let size = NSSize(width: Self.width, height: ceil(hostingView.fittingSize.height))
        panel.setFrame(frame(for: size), display: true)
    }

    private func frame(for size: NSSize) -> NSRect {
        let buttonRect = anchorRect()
        let screen = buttonRect.flatMap { rect in
            NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }
        } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x: CGFloat
        var top: CGFloat
        if let rect = buttonRect, let screen, rect.midY >= screen.frame.maxY - Self.menuBarBand {
            // Left-aligned with the item, like a menu, just below the menu bar. The button sits
            // centred inside the bar, so the bar's bottom is the visible frame's top.
            x = rect.minX
            top = min(rect.minY, visible.maxY) - Self.gap
        } else {
            // No usable item frame yet (right at launch the button reports a placeholder frame
            // below the screen): top right of the screen.
            x = visible.maxX - size.width
            top = visible.maxY - Self.gap
        }
        x = min(x, visible.maxX - size.width - Self.margin)
        x = max(x, visible.minX + Self.margin)
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    /// The status button's frame in screen coordinates.
    private func anchorRect() -> NSRect? {
        guard let anchor, let window = anchor.window else { return nil }
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    /// True when the pointer is over the status item. A click there toggles the panel itself
    /// through the item's action, so the outside-click and resign-key paths leave it alone.
    private func isPointerOnAnchor() -> Bool {
        guard let rect = anchorRect() else { return false }
        return rect.contains(NSEvent.mouseLocation)
    }

    // MARK: - Dismissal

    private func installMonitors() {
        removeMonitors()
        if let outside = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isPointerOnAnchor() else { return }
                    self.close()
                }
            }) {
            monitors.append(outside)
        }
        if let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isOpen else { return false }
                self.close()
                return true
            }
            return handled ? nil : event
        }) {
            monitors.append(escape)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Losing key to a click on the item: its action closes the panel.
        guard !(NSEvent.pressedMouseButtons != 0 && isPointerOnAnchor()) else { return }
        close()
    }
}

/// A borderless panel that can take key status (for `Esc`) without activating the app.
private final class SpoolPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The shape the window server draws the shadow from. While a borderless window is key
    /// its shadow follows the window's rectangle, not the glass, and shows as dark square
    /// corners around the rounded panel (the panel is key whenever it is open, for `Esc`).
    /// `_cornerMask` is AppKit's private hook for that shape; if a later macOS stops asking
    /// for it, the shadow is square again and nothing else changes.
    @objc func _cornerMask() -> NSImage? { Self.cornerMask }

    /// A stretchable rounded rectangle with the panel's corner radius.
    private static let cornerMask: NSImage = {
        let radius = PanelController.cornerRadius
        let image = NSImage(size: NSSize(width: 2 * radius + 1, height: 2 * radius + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }()
}

/// Reports changes of the SwiftUI content's size so the panel can follow it.
private final class PanelHostingView: NSHostingView<PanelView> {
    var onIntrinsicSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeChange?()
    }
}
