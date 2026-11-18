import Foundation

public struct CodexAuth: Equatable, Sendable {
    public var accessToken: String
    public var accountId: String

    public init(accessToken: String, accountId: String) {
        self.accessToken = accessToken
        self.accountId = accountId
    }

    /// Reads `tokens.access_token` and `tokens.account_id` of Codex's auth file. Read only.
    public static func parse(_ data: Data) throws -> CodexAuth {
        let root = try JSONHelpers.object(data)
        guard let tokens = root["tokens"] as? [String: Any] else { throw SpoolError.missingField("tokens") }
        guard let token = tokens["access_token"] as? String else { throw SpoolError.missingField("access_token") }
        guard let account = tokens["account_id"] as? String else { throw SpoolError.missingField("account_id") }
        return CodexAuth(accessToken: token, accountId: account)
    }

    /// Parses Codex's login from the Keychain (`cli_auth_credentials_store = "keyring"`) as
    /// `security find-generic-password -w` prints it. Unverified: the payload is assumed to be
    /// the same JSON as `auth.json`.
    public static func parse(keychainOutput data: Data) throws -> CodexAuth {
        try KeychainOutput.parse(data) { try parse($0) }
    }

    /// Keychain account of Codex's login: `cli|` plus the first 16 hex digits of the SHA-256 of
    /// `codexHome`, the absolute, standardized `CODEX_HOME` path without a trailing slash.
    /// Unverified against a live Codex keyring login; Codex may hash the path in another form
    /// (for example with symlinks resolved).
    public static func keychainAccount(codexHome: String) -> String {
        "cli|" + KeychainOutput.sha256Hex(codexHome).prefix(16)
    }
}
