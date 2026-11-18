import AppKit

/// The menu bar ring: a faint full track and a solid arc for the used fraction, starting at
/// twelve o'clock and running counter-clockwise (a clockwise arc read as the share left). A
/// template image, so the system tints it like its own menu bar icons.
enum RingImage {
    static func make(usedFraction: Double, size: CGFloat = 16) -> NSImage {
        let fraction = usedFraction.isFinite ? min(1, max(0, usedFraction)) : 0
        // Proportions of a 14 pt ring: radius 5.5, stroke 2.
        let lineWidth = size * 2 / 14
        let radius = size * 5.5 / 14
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.black.withAlphaComponent(0.25).setStroke()
            track.stroke()

            if fraction > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius,
                              startAngle: 90, endAngle: 90 + 360 * fraction, clockwise: false)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
