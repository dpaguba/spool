import Foundation

public struct ClaudeCredentials: Equatable, Sendable {
    public var accessToken: String
    public var expiresAt: Date
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public var planLabel: String? {
        switch rateLimitTier {
        case "default_claude_max_5x": return "Max 5x"
        case "default_claude_max_20x": return "Max 20x"
        default: break
        }
        guard let type = subscriptionType, !type.isEmpty else { return nil }
        return type.prefix(1).uppercased() + type.dropFirst()
    }

    /// Reads the `claudeAiOauth` object of Claude Code's credentials. Read only; never refreshed here.
    public static func parse(_ data: Data) throws -> ClaudeCredentials {
        let root = try JSONHelpers.object(data)
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else {
            throw SpoolError.missingField("claudeAiOauth")
        }
        guard let token = oauth["accessToken"] as? String else { throw SpoolError.missingField("accessToken") }
        guard let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue else {
            throw SpoolError.missingField("expiresAt")
        }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: Date(timeIntervalSince1970: ms / 1000),
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String)
    }

    /// Parses the Keychain item as `security find-generic-password -w` prints it (see `KeychainOutput`).
    public static func parse(keychainOutput data: Data) throws -> ClaudeCredentials {
        try KeychainOutput.parse(data) { try parse($0) }
    }

    /// Keychain service of Claude Code's login: `Claude Code-credentials`, with
    /// `-<first 8 hex digits of sha256(CLAUDE_CONFIG_DIR)>` appended when that variable is set.
    public static func keychainService(configDirectory: String?) -> String {
        let base = "Claude Code-credentials"
        guard let configDirectory, !configDirectory.isEmpty else { return base }
        return base + "-" + KeychainOutput.sha256Hex(configDirectory).prefix(8)
    }
}
