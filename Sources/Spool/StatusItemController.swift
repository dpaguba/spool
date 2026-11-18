import AppKit
import Observation
import SpoolCore

/// What the status item shows for one `MenuBarLabel`; shared by the live item and the snapshots.
struct StatusItemContent {
    let image: NSImage
    let title: NSAttributedString
    /// Plain text of `title`, as written to the debug log.
    let text: String
    let accessibilityValue: String

    static var font: NSFont { NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }

    @MainActor
    static func make(_ label: MenuBarLabel,
                     now: Date = .now,
                     locale: Locale = .autoupdatingCurrent,
                     timeZone: TimeZone = .autoupdatingCurrent) -> StatusItemContent {
        let value: String = switch label.text {
        case .until(let date): L10n.until(runOutText(date, now: now, locale: locale, timeZone: timeZone))
        case .percent(let n): "\(n)%"
        // Two middle dots: an en dash is kept for numeric ranges.
        case .noData: "\u{00B7}\u{00B7}"
        }
        let title = NSMutableAttributedString()
        if label.isWeekly {
            title.append(NSAttributedString(string: L10n.weeklyMarker + " ", attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        title.append(NSAttributedString(string: value, attributes: [
            .font: font,
            .foregroundColor: label.isAccent ? Theme.accent : NSColor.labelColor,
        ]))

        let image = RingImage.make(usedFraction: label.usedFraction)
        image.accessibilityDescription = L10n.statusItemDescription
        let accessibilityValue = label.text == .noData ? L10n.noData : title.string
        return StatusItemContent(image: image, title: title, text: title.string,
                                 accessibilityValue: accessibilityValue)
    }

    /// Run-out time for the label: time only ("15:40") when it falls on today's calendar day
    /// in the display time zone, otherwise day and time ("Thu 15:40"), for any window kind.
    static func runOutText(_ date: Date, now: Date, locale: Locale, timeZone: TimeZone) -> String {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        return calendar.isDate(date, inSameDayAs: now)
            ? TimeText.time(date, locale: locale, timeZone: timeZone)
            : TimeText.dayAndTime(date, locale: locale, timeZone: timeZone)
    }
}

/// Owns the menu bar item and redraws it whenever `AppModel.label` changes.
@MainActor final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let model: AppModel
    private let onClick: (NSStatusBarButton) -> Void
    private let debug = ProcessInfo.processInfo.environment["SPOOL_DEBUG"] == "1"

    /// The item's button, which the panel positions itself under.
    var button: NSStatusBarButton? { statusItem.button }

    init(model: AppModel, onClick: @escaping (NSStatusBarButton) -> Void) {
        self.model = model
        self.onClick = onClick
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.setAccessibilityLabel(L10n.statusItemDescription)
        }
        observeLabel()
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        onClick(sender)
    }

    private func observeLabel() {
        withObservationTracking {
            render(model.label)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeLabel() }
        }
    }

    private func render(_ label: MenuBarLabel) {
        guard let button = statusItem.button else { return }
        let content = StatusItemContent.make(label)
        button.image = content.image
        button.attributedTitle = content.title
        button.setAccessibilityValue(content.accessibilityValue)
        if debug {
            FileHandle.standardError.write(Data("label: \(content.text)\n".utf8))
        }
    }
}
