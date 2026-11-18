import Foundation

public enum ConnectionStatus: Equatable, Sendable {
    case notConnected
    case connected
    case needsRepair(currentCommand: String)
    case settingsUnreadable
}

public struct ChainState: Codable, Equatable, Sendable {
    public var previousStatusLine: String?
    public var previousCommand: String?

    public init(previousStatusLine: String? = nil, previousCommand: String? = nil) {
        self.previousStatusLine = previousStatusLine
        self.previousCommand = previousCommand
    }
}

public struct ClaudeCodeConnector: Sendable {
    static let key = "statusLine"
    static let helperName = "spool-statusline"

    public let settingsURL: URL
    let paths: SpoolPaths
    let helperPath: String

    public init(settingsURL: URL, paths: SpoolPaths, helperPath: String) {
        self.settingsURL = settingsURL
        self.paths = paths
        self.helperPath = helperPath
    }

    public static func standardSettingsURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["SPOOL_CLAUDE_SETTINGS"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    // MARK: - Public API

    public func status() -> ConnectionStatus {
        let raw: String?
        do {
            raw = try JSONTopLevelEditor.value(forKey: Self.key, in: try readSettings())
        } catch {
            return .settingsUnreadable
        }
        guard let raw, let command = Self.command(of: raw), Self.isOurs(command) else { return .notConnected }
        return runsThisHelper(raw) ? .connected : .needsRepair(currentCommand: Self.unquoted(command))
    }

    /// The settings file's `stat`, nil without a file. Cheap enough for every reload, so the
    /// app reads the file again (`status()`) only when this changed.
    public func settingsStamp() -> FileStamp? {
        FileStamp(path: settingsURL.path)
    }

    public func connect(now: Date) throws {
        let text = try readSettings()
        let existing = try JSONTopLevelEditor.value(forKey: Self.key, in: text)
        if let existing, let command = Self.command(of: existing), Self.isOurs(command) {
            if runsThisHelper(existing) { return }
            let edited = try JSONTopLevelEditor.setting(try retargeted(existing), forKey: Self.key, in: text)
            try write(edited, now: now)
            return
        }
        let edited = try JSONTopLevelEditor.setting(ownValue(), forKey: Self.key, in: text)
        let state = ChainState(previousStatusLine: existing, previousCommand: existing.flatMap(Self.commandToRun(of:)))
        try write(edited, now: now) {
            try saveChain(state)
        }
    }

    public func disconnect(now: Date) throws {
        let text = try readSettings()
        let existing = try JSONTopLevelEditor.value(forKey: Self.key, in: text)
        let state = try loadChain()
        if let existing, let command = Self.command(of: existing), Self.isOurs(command) {
            let edited: String
            if let previous = state?.previousStatusLine {
                edited = try JSONTopLevelEditor.setting(previous, forKey: Self.key, in: text)
            } else {
                edited = try JSONTopLevelEditor.removing(key: Self.key, in: text)
            }
            try write(edited, now: now)
        }
        try? FileManager.default.removeItem(at: paths.chainState)
    }

    public func repair(now: Date) throws {
        try connect(now: now)
    }

    // MARK: - Helpers

    /// The `statusLine` value: the helper path quoted for the shell Claude Code runs it with.
    private func ownValue() -> String {
        "{ \"type\": \"command\", \"command\": \(ownCommand()) }"
    }

    /// The helper path quoted for the shell, as a JSON string.
    private func ownCommand() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(Self.shellQuoted(helperPath))) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether Claude Code would run exactly this helper for the `statusLine` value `raw`: a
    /// command entry whose command the shell reads as this path alone. An older build wrote the
    /// path unquoted, which still qualifies unless the path has a space or a quote.
    private func runsThisHelper(_ raw: String) -> Bool {
        guard let command = Self.commandToRun(of: raw) else { return false }
        return Self.shellWords(command) == [helperPath]
    }

    /// Spool's own entry `raw` pointed at this helper: `type` and `command` set, every other
    /// member (such as a `padding` the user added) left as it was. A key repeated inside the
    /// entry is reported as the entry's, so the message does not point at the top level.
    private func retargeted(_ raw: String) throws -> String {
        do {
            let typed = try JSONTopLevelEditor.setting("\"command\"", forKey: "type", in: raw)
            return try JSONTopLevelEditor.setting(ownCommand(), forKey: "command", in: typed)
        } catch SpoolError.duplicateKey(let key) {
            throw SpoolError.duplicateKeyInEntry(entry: Self.key, key: key)
        }
    }

    /// `path` as one `/bin/sh` word: in single quotes, each `'` written as `'\''`.
    public static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The words `/bin/sh` splits `command` into, with single quotes, double quotes and
    /// backslashes removed; nil when a quote is left open. Expansions (`$`, `~`, globs) stay
    /// literal text, which is enough to recognise the helper path.
    static func shellWords(_ command: String) -> [String]? {
        let chars = Array(command)
        var words: [String] = []
        var word = ""
        var inWord = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "'":
                guard let end = chars[(i + 1)...].firstIndex(of: "'") else { return nil }
                word.append(contentsOf: chars[(i + 1)..<end])
                inWord = true
                i = end + 1
            case "\"":
                var j = i + 1
                while j < chars.count, chars[j] != "\"" {
                    if chars[j] == "\\", j + 1 < chars.count, "\"\\$`".contains(chars[j + 1]) { j += 1 }
                    word.append(chars[j])
                    j += 1
                }
                guard j < chars.count else { return nil }
                inWord = true
                i = j + 1
            case "\\":
                if i + 1 < chars.count { word.append(chars[i + 1]) }
                inWord = true
                i += 2
            case " ", "\t", "\n":
                if inWord { words.append(word) }
                word = ""
                inWord = false
                i += 1
            default:
                word.append(c)
                inWord = true
                i += 1
            }
        }
        if inWord { words.append(word) }
        return words
    }

    /// The command with its shell quoting removed when the shell reads it as one word, as
    /// `ownValue()` writes it; otherwise (an unquoted path with a space, written by an older
    /// build) the command unchanged.
    static func unquoted(_ command: String) -> String {
        if let words = shellWords(command), words.count == 1 { return words[0] }
        return command
    }

    private static func command(of raw: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]) as? [String: Any],
              let command = object["command"] as? String else { return nil }
        return command
    }

    /// The command Claude Code runs for `raw`: its `command` when `type` is `command`.
    private static func commandToRun(of raw: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]) as? [String: Any],
              object["type"] as? String == "command" else { return nil }
        return object["command"] as? String
    }

    /// Characters that make a raw command more than one plain command for the shell.
    private static let shellOperators = [";", "|", "&", "`", "$(", ">", "<", "\n"]

    /// Whether `command` is Spool's own entry: one shell word naming a `spool-statusline`, as
    /// `ownValue()` writes it, or the bundle path an older build wrote unquoted (which a space
    /// splits or a quote leaves open). Anything else that runs the helper, a compound command
    /// or a wrapper such as `nice` or `env`, is the user's: connect chains it (the inner helper
    /// then does nothing, see `ChainRunner.chainedVariable`) and disconnect restores it.
    static func isOurs(_ command: String) -> Bool {
        if let words = shellWords(command), words.count == 1 {
            return !runsMoreThanOneCommand(command) && isHelper(words[0])
        }
        return isLegacyHelperPath(command)
    }

    /// The form older builds wrote: the helper's absolute path in an app bundle, unquoted. A
    /// space inside it is part of a folder name, so no later word starts a new absolute path
    /// (as the helper does in `/usr/bin/env -i <helper>`), and there is no shell operator.
    private static func isLegacyHelperPath(_ command: String) -> Bool {
        let path = command.trimmingCharacters(in: .whitespaces)
        let chars = Array(path)
        return path.hasPrefix("/") && path.hasSuffix("/Contents/MacOS/\(helperName)")
            && !shellOperators.contains { path.contains($0) }
            && !zip(chars, chars.dropFirst()).contains { $0.isWhitespace && $1 == "/" }
    }

    private static func isHelper(_ path: String) -> Bool {
        path.split(separator: "/").last.map(String.init) == helperName
    }

    /// Whether the shell would run more than the one command `command` names: an operator
    /// outside quotes, or a command substitution outside single quotes. Quotes are balanced
    /// (`shellWords` read it).
    private static func runsMoreThanOneCommand(_ command: String) -> Bool {
        let chars = Array(command)
        var inDoubleQuotes = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                i += 2
                continue
            case "'" where !inDoubleQuotes:
                i = (chars[(i + 1)...].firstIndex(of: "'") ?? chars.count) + 1
                continue
            case "\"":
                inDoubleQuotes.toggle()
            case "`":
                return true
            case "$" where i + 1 < chars.count && chars[i + 1] == "(":
                return true
            case ";", "|", "&", "<", ">", "\n":
                if !inDoubleQuotes { return true }
            default:
                break
            }
            i += 1
        }
        return false
    }

    private var resolvedURL: URL { settingsURL.resolvingSymlinksInPath() }

    private func readSettings() throws -> String {
        let url = resolvedURL
        guard FileManager.default.fileExists(atPath: url.path) else { return "{}" }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { throw SpoolError.malformedJSON }
            return text
        } catch let error as SpoolError {
            throw error
        } catch {
            throw SpoolError.io("\(error)")
        }
    }

    /// Absent file means no previous value; present but unreadable or undecodable throws.
    private func loadChain() throws -> ChainState? {
        guard FileManager.default.fileExists(atPath: paths.chainState.path) else { return nil }
        do {
            return try JSONDecoder().decode(ChainState.self, from: Data(contentsOf: paths.chainState))
        } catch {
            throw SpoolError.io("chain state unreadable: \(error)")
        }
    }

    private func saveChain(_ state: ChainState) throws {
        do {
            try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: paths.chainState, options: .atomic)
        } catch {
            throw SpoolError.io("\(error)")
        }
    }

    /// Backs up the existing file, runs `before`, then replaces the file with `text` in one
    /// rename, keeping its permissions (a new file gets 0644).
    private func write(_ text: String, now: Date, before: () throws -> Void = {}) throws {
        let fm = FileManager.default
        let url = resolvedURL
        do {
            var permissions: mode_t = 0o644
            if fm.fileExists(atPath: url.path) {
                if let mode = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber {
                    permissions = mode_t(mode.uint16Value & 0o7777)
                }
                try backup(url, now: now)
            } else {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try before()
            try AtomicFile.replace(url, with: Data(text.utf8), permissions: permissions)
        } catch let error as SpoolError {
            throw error
        } catch {
            throw SpoolError.io("\(error)")
        }
    }

    private func backup(_ url: URL, now: Date) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        var target = paths.backups.appendingPathComponent("settings-\(stamp).json")
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = paths.backups.appendingPathComponent("settings-\(stamp)-\(n).json")
            n += 1
        }
        try fm.copyItem(at: url, to: target)
    }
}

/// Replaces a file with one `rename(2)`, so a reader sees either the old bytes or the new ones,
/// each with the file's own permissions.
enum AtomicFile {
    /// Writes `data` to a new file in `url`'s directory, created owner-only and set to
    /// `permissions` before any byte is written, then renames it over `url`. `beforeRename`
    /// sees the finished temporary file (tests). A failure up to the rename, `beforeRename`
    /// included, removes the temporary file and leaves `url` as it was.
    static func replace(_ url: URL, with data: Data, permissions: mode_t,
                        beforeRename: (URL) throws -> Void = { _ in }) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).spool-\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SpoolError.io("cannot create \(tmp.path): errno \(errno)") }
        var renamed = false
        defer { if !renamed { unlink(tmp.path) } }
        do {
            defer { close(fd) }
            guard fchmod(fd, permissions) == 0 else { throw SpoolError.io("chmod failed: errno \(errno)") }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw SpoolError.io("write failed: errno \(errno)")
                    }
                    offset += n
                }
            }
        }
        try beforeRename(tmp)
        guard rename(tmp.path, url.path) == 0 else { throw SpoolError.io("rename failed: errno \(errno)") }
        renamed = true
    }
}
