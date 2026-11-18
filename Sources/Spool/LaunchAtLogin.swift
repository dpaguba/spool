import ServiceManagement

/// Spool as a login item (`SMAppService.mainApp`). The system owns the state, so nothing is
/// cached: the user can also remove the item in System Settings.
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// Registered, but the user still has to allow it under Login Items in System Settings.
    static var requiresApproval: Bool { status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }

    /// Name and raw value of `status`, for the debug log.
    static var statusDescription: String {
        let name = switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
        return "\(name) (\(status.rawValue))"
    }
}
