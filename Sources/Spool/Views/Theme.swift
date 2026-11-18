import AppKit
import SwiftUI

/// The single accent of Spool. Used only when the forecast is on and the binding window runs out before its reset.
enum Theme {
    static let accent = NSColor(name: "SpoolAccent") { appearance in
        isDark(appearance)
            ? NSColor(srgbRed: 0xFF / 255, green: 0xB3 / 255, blue: 0x40 / 255, alpha: 1)
            : NSColor(srgbRed: 0xC9 / 255, green: 0x85 / 255, blue: 0x00 / 255, alpha: 1)
    }

    static var accentColor: Color { Color(nsColor: accent) }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        let match = appearance.bestMatch(from: [
            .aqua, .darkAqua, .vibrantLight, .vibrantDark,
            .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark,
        ])
        return match == .darkAqua || match == .vibrantDark
            || match == .accessibilityHighContrastDarkAqua || match == .accessibilityHighContrastVibrantDark
    }
}
