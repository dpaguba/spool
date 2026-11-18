import Foundation
import SpoolCore

/// Reads the logins of the optional sources, read only: Claude Code's OAuth login
/// and Codex's login, each from its file or its generic Keychain item through
/// `/usr/bin/security`. Nothing here writes, refreshes or deletes a login. A secret stays in
/// memory: `security` prints it into a pipe read by this process, its error output is
/// discarded, and nothing is logged.
///
/// Every function here blocks (a Keychain prompt can keep `security` waiting for as long as it
/// is open), so callers go through `run(_:)`.
enum KeychainReader {
    /// Runs `work` on a dispatch queue rather than a Swift concurrency thread.
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }

    // MARK: - Claude Code

    static func claudeCredentials() -> Result<ClaudeCredentials, FetchProblem> {
        let environment = ProcessInfo.processInfo.environment
        // Development and verification: only this file is read, never the Keychain or
        // Claude Code's own file.
        if let path = environment["SPOOL_CLAUDE_CREDENTIALS"], !path.isEmpty {
            return claudeFile(URL(fileURLWithPath: path))
        }
        let configDirectory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let service = ClaudeCredentials.keychainService(configDirectory: configDirectory)
        if let output = password(service: service, account: NSUserName()),
           let credentials = try? ClaudeCredentials.parse(keychainOutput: output) {
            return .success(credentials)
        }
        return claudeFile(claudeCredentialsFile(configDirectory: configDirectory))
    }

    /// When Claude Code last wrote the login `claudeCredentials()` reads, without reading the
    /// secret: the Keychain item's `mdat` from an attribute query (no `-w`, so no prompt for the
    /// password) and the fallback file's modification time.
    static func claudeLoginStamp() -> LoginStamp {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["SPOOL_CLAUDE_CREDENTIALS"], !path.isEmpty {
            return LoginStamp(fileModified: modificationDate(URL(fileURLWithPath: path)))
        }
        let configDirectory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let service = ClaudeCredentials.keychainService(configDirectory: configDirectory)
        let attributes = security(["find-generic-password", "-s", service, "-a", NSUserName()],
                                  capture: true, includeErrorOutput: true)
        return LoginStamp(keychainModified: attributes.flatMap(LoginStamp.keychainModified(fromAttributes:)),
                          fileModified: modificationDate(claudeCredentialsFile(configDirectory: configDirectory)))
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// `$CLAUDE_CONFIG_DIR/.credentials.json`, by default `~/.claude/.credentials.json`.
    private static func claudeCredentialsFile(configDirectory: String?) -> URL {
        let directory = configDirectory.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        return directory.appendingPathComponent(".credentials.json")
    }

    /// A missing, unreadable or unparseable file is no usable login.
    private static func claudeFile(_ url: URL) -> Result<ClaudeCredentials, FetchProblem> {
        guard let data = try? Data(contentsOf: url), let credentials = try? ClaudeCredentials.parse(data) else {
            return .failure(.noCredentials)
        }
        return .success(credentials)
    }

    // MARK: - Codex

    /// Codex's login: `$CODEX_HOME/auth.json` when it holds `tokens.access_token` and
    /// `tokens.account_id`, otherwise the Keychain item Codex writes with
    /// `cli_auth_credentials_store = "keyring"`.
    static func codexAuth() -> Result<CodexAuth, FetchProblem> {
        let home = codexHome()
        if let auth = codexFileAuth(home: home) { return .success(auth) }
        guard let output = password(service: codexService, account: CodexAuth.keychainAccount(codexHome: home.path)),
              let auth = try? CodexAuth.parse(keychainOutput: output) else {
            return .failure(.noCredentials)
        }
        return .success(auth)
    }

    /// Whether a Codex login exists: a usable `auth.json`, or the Keychain item. The item is
    /// looked up by its attributes only, so no secret is read and macOS raises no prompt.
    static func codexLoginExists() -> Bool {
        let home = codexHome()
        if codexFileAuth(home: home) != nil { return true }
        return itemExists(service: codexService, account: CodexAuth.keychainAccount(codexHome: home.path))
    }

    /// `$CODEX_HOME` as an absolute path with `.` and `..` resolved, by default `~/.codex`.
    /// `URL.path` drops a trailing slash. Deliberately not `standardizedFileURL`, which can
    /// strip a leading `/private` and so change the Keychain account hash.
    static func codexHome() -> URL {
        let path = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        return URL(fileURLWithPath: path, isDirectory: true).standardized
    }

    /// `Codex Auth`, or `SPOOL_CODEX_KEYCHAIN_SERVICE` so verification can use a throwaway
    /// item instead of the real one.
    private static var codexService: String {
        ProcessInfo.processInfo.environment["SPOOL_CODEX_KEYCHAIN_SERVICE"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "Codex Auth"
    }

    private static func codexFileAuth(home: URL) -> CodexAuth? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")) else { return nil }
        return try? CodexAuth.parse(data)
    }

    // MARK: - security

    /// The password of a generic Keychain item, or nil when `security` fails (no such item,
    /// or access declined at the macOS prompt).
    private static func password(service: String, account: String) -> Data? {
        guard let output = security(["find-generic-password", "-s", service, "-a", account, "-w"], capture: true),
              !output.isEmpty else { return nil }
        return output
    }

    /// Whether a generic Keychain item exists. Without `-w` (or `-g`) `security` reads only
    /// the item's attributes, and even those are discarded here.
    private static func itemExists(service: String, account: String) -> Bool {
        security(["find-generic-password", "-s", service, "-a", account], capture: false) != nil
    }

    /// Runs `/usr/bin/security` with stdin and stderr on /dev/null. Returns nil on a non-zero
    /// exit; otherwise stdout read into memory when `capture`, or empty data (stdout discarded).
    /// `includeErrorOutput` captures stderr into the same data, for attribute queries only
    /// (which print no secret on either stream).
    private static func security(_ arguments: [String], capture: Bool, includeErrorOutput: Bool = false) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = capture ? Pipe() : nil
        process.standardOutput = output ?? FileHandle.nullDevice
        if includeErrorOutput, let output {
            process.standardError = output
        } else {
            process.standardError = FileHandle.nullDevice
        }
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read to the end before waiting, so a full pipe cannot hold `security` up.
        let data = output.flatMap { try? $0.fileHandleForReading.readToEnd() } ?? Data()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
