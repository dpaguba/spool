import SwiftUI

/// The panel's large ring: a faint full track and a solid arc for the
/// used fraction, from twelve o'clock counter-clockwise like the menu bar ring. Monochrome in
/// every state.
struct RingView: View {
    /// Used fraction, 0...1.
    let fraction: Double
    var diameter: CGFloat = 64
    var lineWidth: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Proportions: radius 27 with a 6 pt stroke inside a 64 pt box.
        let inset = diameter / 2 - diameter * 27 / 64
        ZStack {
            Circle()
                .inset(by: inset)
                .stroke(.quaternary, lineWidth: lineWidth)
            if clamped > 0 {
                Circle()
                    .inset(by: inset)
                    .trim(from: 1 - clamped, to: 1)
                    .stroke(.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: clamped)
        .accessibilityHidden(true)
    }

    private var clamped: Double {
        fraction.isFinite ? min(1, max(0, fraction)) : 0
    }
}
