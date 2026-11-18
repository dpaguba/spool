import SpoolCore
import SwiftUI

/// What the panel shows before any usage data exists: a note that Spool is waiting for Claude
/// Code's first response, or what keeps the status line from feeding Spool with the action
/// that fixes it (connect, repair, or the settings window for a file Spool cannot read).
struct EmptyStateView: View {
    let connection: ConnectionStatus
    /// The Claude Code settings file, with the home folder as `~`.
    let settingsPath: String
    let error: String?
    let connect: () -> Void
    let repair: () -> Void
    let openSettings: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.top, 12)
            }
            if let error {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        switch connection {
        case .connected: L10n.waitingTitle
        case .notConnected: L10n.notConnectedTitle
        case .needsRepair: L10n.needsRepairTitle
        case .settingsUnreadable: L10n.unreadableTitle
        }
    }

    private var message: String {
        switch connection {
        case .connected: L10n.waitingBody
        case .notConnected: L10n.notConnectedBody
        case .needsRepair: L10n.needsRepairBody
        case .settingsUnreadable: L10n.unreadableBody(settingsPath: settingsPath)
        }
    }

    private var actionTitle: String? {
        switch connection {
        case .connected: nil
        case .notConnected: L10n.connectClaudeCode
        case .needsRepair: L10n.repair
        case .settingsUnreadable: L10n.openSettings
        }
    }

    private func action() {
        switch connection {
        case .connected: break
        case .notConnected: connect()
        case .needsRepair: repair()
        case .settingsUnreadable: openSettings()
        }
    }
}
