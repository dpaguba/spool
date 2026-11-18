import AppKit
import SwiftUI

/// The settings window: a standard titled window around `SettingsView`. Showing it activates
/// the app and brings the window to the front; closing it only hides it (the app keeps running
/// in the menu bar).
@MainActor final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let preferences: Preferences
    private let notifier: Notifier
    private var window: NSWindow?

    init(model: AppModel, preferences: Preferences, notifier: Notifier) {
        self.model = model
        self.preferences = preferences
        self.notifier = notifier
        super.init()
    }

    func show() {
        let window = self.window ?? makeWindow()
        if !window.isVisible {
            // A fresh view on every open reads the login item and connection state anew.
            model.reload(checkConnection: true)
            model.refreshCodexDetection()
            let screen = window.screen ?? NSScreen.main
            let hosting = NSHostingView(rootView: SettingsView(model: model, preferences: preferences, notifier: notifier,
                                                               maxHeight: Self.maxContentHeight(window, on: screen)))
            window.contentView = hosting
            // Measured inside the window: measured before, a grouped form reports a few points
            // more than it draws.
            hosting.layoutSubtreeIfNeeded()
            window.setContentSize(hosting.fittingSize)
            if self.window == nil { window.center() }
            if let screen { keep(window, inside: screen.visibleFrame) }
            Task { await notifier.refreshAuthorization() }
        }
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Activation can be refused while another app holds the user's attention; the window
        // still comes to the front.
        window.orderFrontRegardless()
        if ProcessInfo.processInfo.environment["SPOOL_DEBUG"] == "1" {
            let size = window.contentLayoutRect.size
            FileHandle.standardError.write(Data("settings: shown \(Int(size.width))x\(Int(size.height))\n".utf8))
        }
    }

    /// Closes the window as its close button does.
    func close() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["SPOOL_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("settings: closed\n".utf8))
        }
        // Drop the SwiftUI tree once the window is gone, so nothing updates while it is closed.
        Task { @MainActor [weak self] in
            guard let window = self?.window, !window.isVisible else { return }
            window.contentView = nil
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // The status line may have been edited by hand while the window was in the background,
        // and a Codex login may have appeared or gone.
        model.reload(checkConnection: true)
        model.refreshCodexDetection()
    }

    /// Room for the content on `screen`: its visible height less the title bar and a margin
    /// above and below. Unlimited without a screen.
    private static func maxContentHeight(_ window: NSWindow, on screen: NSScreen?) -> CGFloat {
        guard let screen else { return .infinity }
        let titleBar = window.frameRect(forContentRect: .zero).height
        let margin: CGFloat = 24
        return max(200, screen.visibleFrame.height - titleBar - 2 * margin)
    }

    /// Moves the window back inside `visible` when its new height pushed it past an edge.
    private func keep(_ window: NSWindow, inside visible: NSRect) {
        var frame = window.frame
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    private func makeWindow() -> NSWindow {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: 400),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = L10n.settingsTitle
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        return window
    }
}

/// Closes on Command-W, which has no menu item to go through in a menu bar app.
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
