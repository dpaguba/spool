import AppKit
import SpoolCore
import SwiftUI

/// `Spool --snapshot <dir>`: renders fixed fixtures to PNG files for review, without a screen capture.
@MainActor enum Snapshot {
    static func run(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = fixtureNow()
        for (state, label) in labelFixtures(now: now) {
            for appearance in Appearance.allCases {
                let png = try renderLabel(label, now: now, appearance: appearance)
                try png.write(to: directory.appendingPathComponent("label-\(state)-\(appearance.rawValue).png"))
            }
        }
        _ = NSApplication.shared
        for fixture in panelFixtures(now: now) {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("spool-snapshot-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let model = try panelModel(fixture, now: now, in: scratch)
            for appearance in Appearance.allCases {
                let png = try renderPanel(model, appearance: appearance)
                try png.write(to: directory.appendingPathComponent("panel-\(fixture.name)-\(appearance.rawValue).png"))
            }
        }
        try renderSettingsSnapshots(to: directory, now: now)
    }

    // MARK: - Menu bar label

    enum Appearance: String, CaseIterable {
        case light, dark

        var appearance: NSAppearance {
            NSAppearance(named: self == .light ? .aqua : .darkAqua)!
        }

        /// Opaque stand-ins for the translucent menu bar.
        var menuBarBackground: NSColor {
            self == .light
                ? NSColor(srgbRed: 246 / 255, green: 246 / 255, blue: 246 / 255, alpha: 1)
                : NSColor(srgbRed: 40 / 255, green: 40 / 255, blue: 42 / 255, alpha: 1)
        }
    }

    /// "Now" of every fixture: 14:23 today.
    static func fixtureNow() -> Date {
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.startOfDay(for: .now)
        return calendar.date(bySettingHour: 14, minute: 23, second: 0, of: day) ?? day
    }

    /// Every menu bar label state, built through the pipeline the app uses.
    static func labelFixtures(now: Date) -> [(String, MenuBarLabel)] {
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.startOfDay(for: now)
        func at(_ hour: Int, _ minute: Int, daysLater: Int = 0) -> Date {
            let date = calendar.date(byAdding: .day, value: daysLater, to: day) ?? day
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
        }
        func window(_ kind: WindowKind, used: Double, resetsAt: Date) -> LimitWindow {
            LimitWindow(provider: .claude, kind: kind, usedPercent: used, resetsAt: resetsAt,
                        length: kind == .session ? WindowLength.session : WindowLength.week,
                        observedAt: now, source: .statusline)
        }
        func label(_ items: [Assessment]) -> MenuBarLabel {
            let binding = BindingWindow.pick(items, forecastEnabled: true, now: now)
            return MenuBarLabelBuilder.make(binding: binding, forecastEnabled: true, now: now)
        }
        let session = window(.session, used: 62, resetsAt: at(16, 10))
        return [
            ("until", label([Assessment(window: session, verdict: .runsOut(at: at(15, 40)))])),
            ("percent", label([Assessment(window: session, verdict: .enough(remainingAtReset: 12))])),
            // The weekly marker shows only when there is no 5-hour window.
            ("weekly", label([
                Assessment(window: window(.weekly, used: 97, resetsAt: now.addingTimeInterval(2 * 86_400)),
                           verdict: .enough(remainingAtReset: 1)),
            ])),
            ("weekly-runsout", label([
                Assessment(window: window(.weekly, used: 80, resetsAt: at(9, 0, daysLater: 3)),
                           verdict: .runsOut(at: at(15, 40, daysLater: 2))),
            ])),
            ("nodata", label([])),
            ("reset", label([Assessment(window: window(.session, used: 90, resetsAt: at(13, 10)),
                                        verdict: .enough(remainingAtReset: 100))])),
        ]
    }

    /// The status item content on a menu-bar-like strip, at 2x.
    static func renderLabel(_ label: MenuBarLabel, now: Date, appearance: Appearance) throws -> Data {
        let scale: CGFloat = 2
        var png: Data?
        appearance.appearance.performAsCurrentDrawingAppearance {
            let content = StatusItemContent.make(label, now: now)
            let imageSize = content.image.size
            let titleSize = content.title.size()
            let height: CGFloat = 24
            let padding: CGFloat = 12
            let gap: CGFloat = 4
            let width = max(120, ceil(padding + imageSize.width + gap + titleSize.width + padding))
            let tint = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black

            guard let ring = tinted(content.image, color: tint, scale: scale),
                  let context = bitmapContext(width: width, height: height, scale: scale) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            appearance.menuBarBackground.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            let imageRect = NSRect(x: padding, y: ((height - imageSize.height) / 2).rounded(),
                                   width: imageSize.width, height: imageSize.height)
            context.draw(ring, in: imageRect)
            content.title.draw(at: NSPoint(x: imageRect.maxX + gap, y: (height - titleSize.height) / 2))
            NSGraphicsContext.restoreGraphicsState()

            if let image = context.makeImage() {
                png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }
        }
        guard let png else { throw SpoolError.io("cannot render label snapshot") }
        return png
    }

    // MARK: - Panel

    /// The state of the Claude Code settings file a fixture starts from.
    enum FixtureConnection {
        case connected, notConnected, needsRepair, unreadable
    }

    struct PanelFixture {
        let name: String
        let forecastEnabled: Bool
        let connection: FixtureConnection
        let observations: [(t: Date, windows: [LimitWindow])]
        /// Plan name as Detailed limits would supply it.
        var planLabel: String? = nil
    }

    /// The panel states, as stored observations run through the app's own `reload()`.
    static func panelFixtures(now: Date) -> [PanelFixture] {
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.startOfDay(for: now)
        func at(_ hour: Int, _ minute: Int, daysLater: Int = 0) -> Date {
            let date = calendar.date(byAdding: .day, value: daysLater, to: day) ?? day
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
        }
        func window(_ kind: WindowKind, used: Double, resetsAt: Date, at t: Date,
                    provider: Provider = .claude) -> LimitWindow {
            LimitWindow(provider: provider, kind: kind, usedPercent: used, resetsAt: resetsAt,
                        length: kind == .session ? WindowLength.session : WindowLength.week,
                        observedAt: t,
                        source: provider == .codex ? .codexAPI : kind == .session || kind == .weekly ? .statusline : .oauth)
        }

        // A sample day: 5-hour window from 11:10 to 16:10, now 14:23 with 62% used; the week
        // resets six days later at 09:00, a per-model week next to it.
        let sessionReset = at(16, 10)
        let weekReset = at(9, 0, daysLater: 6)
        func claudeDay(_ session: [(Int, Int, Double)]) -> [(t: Date, windows: [LimitWindow])] {
            session.map { hour, minute, used in
                let t = at(hour, minute)
                return (t, [
                    window(.session, used: used, resetsAt: sessionReset, at: t),
                    window(.weekly, used: 10 + used / 15.5, resetsAt: weekReset, at: t),
                    window(.weeklyModel("Fable"), used: 4 + used / 15.5, resetsAt: weekReset, at: t),
                ])
            }
        }
        // Over the last 30 minutes the pace leads to 100% at 15:40, before the 16:10 reset.
        let runsOut = claudeDay([
            (11, 22, 4), (11, 48, 9), (12, 15, 15), (12, 41, 21), (13, 8, 30),
            (13, 31, 39), (13, 50, 47.2), (14, 4, 53), (14, 14, 58), (14, 23, 62),
        ])
        // Busy morning, quiet last half hour: about a quarter of the window left at reset.
        let enough = claudeDay([
            (11, 22, 6), (11, 50, 14), (12, 20, 25), (12, 50, 37), (13, 20, 50),
            (13, 45, 58), (13, 55, 59.5), (14, 10, 61), (14, 23, 62),
        ])

        // A 5-hour window 40% used, the week 97% used and running out today.
        let weekStartReset = at(9, 0, daysLater: 2)
        let weekly: [(Int, Int, Int, Double)] = [
            (-5, 11, 0, 6), (-4, 15, 0, 24), (-3, 12, 0, 41), (-2, 18, 0, 63), (-1, 13, 0, 80),
            (0, 10, 30, 90), (0, 12, 0, 93), (0, 13, 30, 95.5), (0, 14, 23, 97),
        ]
        let todaySession: [Int: Double] = [10: 0, 12: 22, 13: 33, 14: 40]
        let weeklyBinding = weekly.map { daysLater, hour, minute, used in
            let t = at(hour, minute, daysLater: daysLater)
            var windows = [
                window(.weekly, used: used, resetsAt: weekStartReset, at: t),
                window(.weeklyModel("Fable"), used: used * 0.4, resetsAt: weekStartReset, at: t),
            ]
            if daysLater == 0, let session = todaySession[hour] {
                windows.append(window(.session, used: session, resetsAt: sessionReset, at: t))
            }
            return (t: t, windows: windows)
        }

        // Forecast off and no 5-hour window (Ultra), so the week is on top; it resets tomorrow
        // at 09:00, under a day away: the reset shows a weekday and the countdown runs over
        // many hours.
        let tomorrowReset = at(9, 0, daysLater: 1)
        let resetTomorrow = [(-5, 12, 0, 20.0), (-3, 15, 0, 45), (-1, 18, 0, 70), (0, 11, 0, 82), (0, 14, 23, 88)]
            .map { daysLater, hour, minute, used in
                let t = at(hour, minute, daysLater: daysLater)
                return (t: t, windows: [
                    window(.weekly, used: used, resetsAt: tomorrowReset, at: t),
                    window(.weeklyModel("Fable"), used: used * 0.55, resetsAt: tomorrowReset, at: t),
                ])
            }

        let codex = [(12, 30, 8.0, 40.0), (13, 40, 15, 43), (14, 20, 20, 45)].map { hour, minute, session, week in
            let t = at(hour, minute)
            return (t: t, windows: [
                window(.session, used: session, resetsAt: at(17, 0), at: t, provider: .codex),
                window(.weekly, used: week, resetsAt: at(9, 0, daysLater: 4), at: t, provider: .codex),
            ])
        }

        // The same week without a 5-hour window: the weekly chart is on top.
        let weeklyOnly = weeklyBinding.map { observation in
            (t: observation.t, windows: observation.windows.filter { $0.kind != .session })
        }

        // The same day with only what the status line reported (no Detailed limits windows).
        let statuslineOnly = runsOut.map { observation in
            (t: observation.t, windows: observation.windows.filter { $0.source == .statusline })
        }

        return [
            PanelFixture(name: "forecast-runsout", forecastEnabled: true, connection: .connected, observations: runsOut,
                         planLabel: "Max 5x"),
            PanelFixture(name: "forecast-enough", forecastEnabled: true, connection: .connected, observations: enough),
            PanelFixture(name: "ring", forecastEnabled: false, connection: .connected, observations: runsOut),
            PanelFixture(name: "ring-reset-tomorrow", forecastEnabled: false, connection: .connected,
                         observations: resetTomorrow),
            // The week runs out first, yet the 5-hour window stays on top.
            PanelFixture(name: "weekly-low", forecastEnabled: true, connection: .connected, observations: weeklyBinding),
            PanelFixture(name: "weekly-only", forecastEnabled: true, connection: .connected, observations: weeklyOnly),
            PanelFixture(name: "two-providers", forecastEnabled: true, connection: .connected,
                         observations: (runsOut + codex).sorted { $0.t < $1.t }),
            PanelFixture(name: "not-connected", forecastEnabled: true, connection: .notConnected, observations: []),
            PanelFixture(name: "waiting", forecastEnabled: true, connection: .connected, observations: []),
            // The app was moved: the stored numbers stay, and the panel says why nothing new arrives.
            PanelFixture(name: "needs-repair", forecastEnabled: true, connection: .needsRepair, observations: runsOut),
            PanelFixture(name: "needs-repair-empty", forecastEnabled: true, connection: .needsRepair, observations: []),
            // Another tool replaced the status line, or the settings file is broken.
            PanelFixture(name: "connection-lost", forecastEnabled: true, connection: .notConnected,
                         observations: statuslineOnly),
            PanelFixture(name: "unreadable", forecastEnabled: true, connection: .unreadable,
                         observations: statuslineOnly),
        ]
    }

    /// An `AppModel` over a scratch data directory and settings file, reloaded at `now`.
    static func panelModel(_ fixture: PanelFixture, now: Date, in directory: URL,
                           preferences: Preferences? = nil) throws -> AppModel {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = SpoolPaths(directory: directory)
        let store = SampleStore(paths: paths)
        for observation in fixture.observations {
            _ = try store.append(observation.windows, at: observation.t)
        }
        // "Updated" follows the file's modification time too: stamp it with the newest fixture.
        if let newest = fixture.observations.map(\.t).max() {
            try FileManager.default.setAttributes([.modificationDate: newest], ofItemAtPath: paths.observations.path)
        }
        let settings = directory.appendingPathComponent("settings.json")
        let helper = directory.appendingPathComponent("spool-statusline").path
        switch fixture.connection {
        case .connected, .needsRepair:
            let command = fixture.connection == .connected
                ? ClaudeCodeConnector.shellQuoted(helper)
                : "/Applications/Old/Spool.app/Contents/MacOS/spool-statusline"
            let value = try JSONEncoder().encode(["statusLine": ["type": "command", "command": command]])
            try value.write(to: settings)
        case .notConnected:
            break
        case .unreadable:
            try Data("{\"statusLine\": ".utf8).write(to: settings)
        }
        let connector = ClaudeCodeConnector(settingsURL: settings, paths: paths, helperPath: helper)
        let preferences = try preferences ?? fixturePreferences(forecastEnabled: fixture.forecastEnabled)
        let model = AppModel(store: store, connector: connector, preferences: preferences, now: { now })
        model.reload()
        model.showFixtureSources([:], planLabel: fixture.planLabel, codexLoginFound: false)
        return model
    }

    /// Preferences whose registered values live only in memory, so nothing is written to any
    /// defaults domain. Both optional sources are on by default here, because the fixtures
    /// hold per-model weekly (Detailed limits) and Codex windows, which the app shows only then.
    static func fixturePreferences(forecastEnabled: Bool, detailedLimits: Bool = true,
                                   codex: Bool = true) throws -> Preferences {
        guard let defaults = UserDefaults(suiteName: "spool-snapshot-\(UUID().uuidString)") else {
            throw SpoolError.io("cannot create snapshot defaults")
        }
        defaults.register(defaults: ["forecastEnabled": forecastEnabled, "detailedLimitsEnabled": detailedLimits,
                                     "codexEnabled": codex])
        return Preferences(defaults: defaults)
    }

    /// The panel at 2x on an opaque window-background stand-in for the glass.
    static func renderPanel(_ model: AppModel, appearance: Appearance) throws -> Data {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let content = PanelView(model: model, liveClock: false)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = appearance.appearance
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance.appearance
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw SpoolError.io("cannot create panel bitmap") }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SpoolError.io("cannot encode panel snapshot")
        }
        return png
    }

    // MARK: - Settings

    /// Settings over the "two-providers" fixture (connected), launch at login off:
    /// - `settings-<appearance>.png`: both optional sources on and checked, so the menu bar
    ///   provider picker shows;
    /// - `settings-confirm-<appearance>.png`: both off, Detailed limits just switched on and
    ///   waiting for Enable, no Codex login on this Mac;
    /// - `settings-problems-<appearance>.png`: both on, Claude paused on an expired login,
    ///   Codex rate limited;
    /// - `settings-capped-<appearance>.png`: as `settings`, on a screen with room for 520 pt, so
    ///   the form scrolls inside the capped window.
    static func renderSettingsSnapshots(to directory: URL, now: Date) throws {
        guard let fixture = panelFixtures(now: now).first(where: { $0.name == "two-providers" }) else { return }
        let calendar = Calendar.autoupdatingCurrent
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        }
        let checked: [Provider: SourceState] = [.claude: .checked(now), .codex: .checked(at(14, 20))]
        let variants: [(name: String, sourcesOn: Bool, confirming: Bool, states: [Provider: SourceState], found: Bool,
                        maxHeight: CGFloat)] = [
            ("settings", true, false, checked, true, .infinity),
            ("settings-confirm", false, true, [:], false, .infinity),
            ("settings-problems", true, false,
             [.claude: .failed(.tokenExpired), .codex: .failed(.rateLimited(until: at(15, 10)))], true, .infinity),
            ("settings-capped", true, false, checked, true, 520),
        ]
        for variant in variants {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("spool-snapshot-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let preferences = try fixturePreferences(forecastEnabled: fixture.forecastEnabled,
                                                     detailedLimits: variant.sourcesOn, codex: variant.sourcesOn)
            let model = try panelModel(fixture, now: now, in: scratch, preferences: preferences)
            model.showFixtureSources(variant.states, planLabel: nil, codexLoginFound: variant.found)
            for appearance in Appearance.allCases {
                let view = SettingsView(model: model, preferences: preferences, notifier: Notifier(), live: false,
                                        maxHeight: variant.maxHeight, confirmingDetailedLimits: variant.confirming)
                let png = try renderWindowContent(view, appearance: appearance)
                try png.write(to: directory.appendingPathComponent("\(variant.name)-\(appearance.rawValue).png"))
            }
        }
    }

    /// A SwiftUI view at its ideal size on an offscreen window, at 2x.
    static func renderWindowContent(_ view: some View, appearance: Appearance) throws -> Data {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance.appearance
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // Measured inside the window, as the settings window does: measured before, a grouped
        // form reports a few points more than it draws.
        let size = hosting.fittingSize
        window.setContentSize(size)
        hosting.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw SpoolError.io("cannot create settings bitmap") }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SpoolError.io("cannot encode settings snapshot")
        }
        return png
    }

    // MARK: - Drawing helpers

    private static func bitmapContext(width: CGFloat, height: CGFloat, scale: CGFloat) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        return context
    }

    /// Draws a template image the way the menu bar does: its alpha filled with `color`.
    private static func tinted(_ image: NSImage, color: NSColor, scale: CGFloat) -> CGImage? {
        let size = image.size
        guard let context = bitmapContext(width: size.width, height: size.height, scale: scale) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let rect = NSRect(origin: .zero, size: size)
        image.draw(in: rect)
        color.setFill()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
