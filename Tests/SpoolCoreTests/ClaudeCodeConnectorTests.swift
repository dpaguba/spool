import Foundation
import Testing
@testable import SpoolCore

struct ClaudeCodeConnectorTests {
    let helper = "/tmp/Spool.app/Contents/MacOS/spool-statusline"
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func makeEnv(settings: String?, helper: String? = nil) throws
        -> (connector: ClaudeCodeConnector, settings: URL, paths: SpoolPaths) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settingsURL = dir.appendingPathComponent("claude/settings.json")
        if let settings {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(settings.utf8).write(to: settingsURL)
        }
        let paths = SpoolPaths(directory: dir.appendingPathComponent("data", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        return (ClaudeCodeConnector(settingsURL: settingsURL, paths: paths, helperPath: helper ?? self.helper),
                settingsURL, paths)
    }

    func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func backups(_ paths: SpoolPaths) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.backups.path)) ?? []).sorted()
    }
    func chain(_ paths: SpoolPaths) throws -> ChainState {
        try JSONDecoder().decode(ChainState.self, from: Data(contentsOf: paths.chainState))
    }
    /// The `statusLine.command` string exactly as stored in the settings file.
    func storedCommand(_ url: URL) throws -> String? {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return (root?["statusLine"] as? [String: Any])?["command"] as? String
    }
    func legacySettings(_ command: String) -> String {
        "{\"statusLine\": {\"type\": \"command\", \"command\": \"\(command)\"}}"
    }

    @Test func connectOnPlainSettings() throws {
        let env = try makeEnv(settings: "{\n  \"theme\": \"dark\"\n}\n")
        #expect(env.connector.status() == .notConnected)
        try env.connector.connect(now: now)
        #expect(env.connector.status() == .connected)
        #expect(backups(env.paths).count == 1)
        let state = try chain(env.paths)
        #expect(state.previousStatusLine == nil)
        #expect(state.previousCommand == nil)
        #expect(try read(env.settings).contains("\"theme\": \"dark\""))
    }

    @Test func connectOverForeignStatusLineChains() throws {
        let raw = #"{"type":"command","command":"~/bin/my-line"}"#
        let text = "{\n  \"statusLine\": \(raw),\n  \"theme\": \"dark\"\n}\n"
        let env = try makeEnv(settings: text)
        try env.connector.connect(now: now)
        let state = try chain(env.paths)
        #expect(state.previousStatusLine == raw)
        #expect(state.previousCommand == "~/bin/my-line")
        #expect(env.connector.status() == .connected)
        try env.connector.disconnect(now: now)
        #expect(try read(env.settings) == text)
        #expect(!FileManager.default.fileExists(atPath: env.paths.chainState.path))
        #expect(env.connector.status() == .notConnected)
    }

    @Test func nonCommandPreviousHasNoPreviousCommand() throws {
        let env = try makeEnv(settings: "{\"statusLine\": \"weird\"}")
        try env.connector.connect(now: now)
        let state = try chain(env.paths)
        #expect(state.previousStatusLine == "\"weird\"")
        #expect(state.previousCommand == nil)
    }

    @Test func disconnectWithoutPreviousRemovesKey() throws {
        let text = "{\n  \"theme\": \"dark\"\n}\n"
        let env = try makeEnv(settings: text)
        try env.connector.connect(now: now)
        try env.connector.disconnect(now: now)
        #expect(try read(env.settings) == text)
        #expect(!FileManager.default.fileExists(atPath: env.paths.chainState.path))
    }

    @Test func corruptChainStateBlocksDisconnect() throws {
        let raw = #"{"type":"command","command":"~/bin/my-line"}"#
        let env = try makeEnv(settings: "{\"statusLine\": \(raw)}")
        try env.connector.connect(now: now)
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: env.paths.chainState)
        let before = try Data(contentsOf: env.settings)
        let backupsBefore = backups(env.paths)
        #expect(throws: SpoolError.self) { try env.connector.disconnect(now: now) }
        #expect(try Data(contentsOf: env.settings) == before)
        #expect(try Data(contentsOf: env.paths.chainState) == corrupt)
        #expect(backups(env.paths) == backupsBefore)
    }

    @Test func movedAppNeedsRepair() throws {
        let old = "/old/Spool.app/Contents/MacOS/spool-statusline"
        let env = try makeEnv(settings: "{\"statusLine\": {\"type\": \"command\", \"command\": \"\(old)\"}}")
        #expect(env.connector.status() == .needsRepair(currentCommand: old))
        try env.connector.repair(now: now)
        #expect(env.connector.status() == .connected)
        #expect(try read(env.settings).contains(helper))
        #expect(!(try read(env.settings).contains(old)))
    }

    @Test func invalidSettingsAreUntouched() throws {
        let bad = "{\"a\": 1,}"
        let env = try makeEnv(settings: bad)
        #expect(env.connector.status() == .settingsUnreadable)
        #expect(throws: SpoolError.malformedJSON) { try env.connector.connect(now: now) }
        #expect(try read(env.settings) == bad)
        #expect(backups(env.paths).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.paths.chainState.path))
    }

    @Test func missingSettingsFileIsCreated() throws {
        let env = try makeEnv(settings: nil)
        #expect(env.connector.status() == .notConnected)
        try env.connector.connect(now: now)
        #expect(env.connector.status() == .connected)
    }

    @Test func twoWritesInOneSecondKeepBothBackups() throws {
        let env = try makeEnv(settings: "{}")
        try env.connector.connect(now: now)
        try env.connector.disconnect(now: now)
        let names = backups(env.paths)
        #expect(names.count == 2)
        #expect(Set(names).count == 2)
    }

    @Test func symlinkIsEditedInPlaceAndPermissionsKept() throws {
        let env = try makeEnv(settings: nil)
        let dir = env.settings.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("real.json")
        try Data("{}".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: env.settings, withDestinationURL: real)
        try env.connector.connect(now: now)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: env.settings.path)) != nil)
        #expect(try read(real).contains("spool-statusline"))
        let perms = try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int
        #expect(perms == 0o640)
    }

    @Test func helperPathWithSpaceAndQuoteRoundTrips() throws {
        let text = "{\n  \"theme\": \"dark\"\n}\n"
        let env = try makeEnv(settings: text)
        // A real executable at a path with a space and a single quote, so the shell run is real.
        let macOS = env.paths.directory.deletingLastPathComponent()
            .appendingPathComponent("My Apps/Jo's Spool.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let helperURL = macOS.appendingPathComponent("spool-statusline")
        try Data("#!/bin/sh\ncat >/dev/null\nprintf ran\n".utf8).write(to: helperURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        let connector = ClaudeCodeConnector(settingsURL: env.settings, paths: env.paths, helperPath: helperURL.path)

        #expect(connector.status() == .notConnected)
        try connector.connect(now: now)
        #expect(connector.status() == .connected)
        let command = try #require(try storedCommand(env.settings))
        #expect(command == "'" + helperURL.path.replacingOccurrences(of: "'", with: #"'\''"#) + "'")
        // Claude Code runs the command through a shell; the quoted form reaches the helper.
        #expect(String(decoding: ChainRunner.run(command: command, input: Data("{}".utf8)), as: UTF8.self) == "ran")

        // Another copy of the app sees the quoted path as its own old location and repairs it.
        let moved = ClaudeCodeConnector(settingsURL: env.settings, paths: env.paths, helperPath: helper)
        #expect(moved.status() == .needsRepair(currentCommand: helperURL.path))
        try moved.repair(now: now)
        #expect(moved.status() == .connected)
        #expect(connector.status() == .needsRepair(currentCommand: helper))
        try connector.repair(now: now)
        #expect(connector.status() == .connected)
        #expect(try storedCommand(env.settings) == command)

        try connector.disconnect(now: now)
        #expect(try read(env.settings) == text)
        #expect(connector.status() == .notConnected)
    }

    @Test func legacyUnquotedHelperIsOurs() throws {
        // Written unquoted by an earlier build at this location: the shell runs it unchanged.
        let same = try makeEnv(settings: legacySettings(helper))
        #expect(same.connector.status() == .connected)

        // Unquoted at another location: Spool's own, just moved.
        let old = "/old/Spool.app/Contents/MacOS/spool-statusline"
        let moved = try makeEnv(settings: legacySettings(old))
        #expect(moved.connector.status() == .needsRepair(currentCommand: old))
        try moved.connector.connect(now: now)
        #expect(!FileManager.default.fileExists(atPath: moved.paths.chainState.path))
        #expect(try storedCommand(moved.settings) == "'\(helper)'")

        // Unquoted with a space: the shell splits it, so this location needs repair too.
        let spaced = "/Applications/My Apps/Spool.app/Contents/MacOS/spool-statusline"
        let split = try makeEnv(settings: legacySettings(spaced), helper: spaced)
        #expect(split.connector.status() == .needsRepair(currentCommand: spaced))
        try split.connector.repair(now: now)
        #expect(split.connector.status() == .connected)
        #expect(try storedCommand(split.settings) == "'\(spaced)'")
        #expect(!FileManager.default.fileExists(atPath: split.paths.chainState.path))

        // Disconnect takes an unquoted value away as Spool's own.
        let gone = try makeEnv(settings: legacySettings(spaced))
        try gone.connector.disconnect(now: now)
        #expect(try storedCommand(gone.settings) == nil)
        #expect(gone.connector.status() == .notConnected)
    }

    @Test func shellWordsFollowShQuoting() {
        #expect(ClaudeCodeConnector.shellWords("/a/b") == ["/a/b"])
        #expect(ClaudeCodeConnector.shellWords("'/a b/c'\\''d'") == ["/a b/c'd"])
        #expect(ClaudeCodeConnector.shellWords(#""/a \"b\"" c\ d"#) == [#"/a "b""#, "c d"])
        #expect(ClaudeCodeConnector.shellWords("  x   y ") == ["x", "y"])
        #expect(ClaudeCodeConnector.shellWords("'open") == nil)
        #expect(ClaudeCodeConnector.shellWords(#""open"#) == nil)
        #expect(ClaudeCodeConnector.shellQuoted("/a b/it's") == #"'/a b/it'\''s'"#)
    }

    func mode(_ path: String) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    }

    @Test func privateSettingsStayPrivateThroughConnectAndDisconnect() throws {
        let env = try makeEnv(settings: "{\"env\": {\"TOKEN\": \"secret\"}}")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.settings.path)
        try env.connector.connect(now: now)
        #expect(try mode(env.settings.path) == 0o600)
        try env.connector.disconnect(now: now)
        #expect(try mode(env.settings.path) == 0o600)
        for name in backups(env.paths) {
            #expect(try mode(env.paths.backups.appendingPathComponent(name).path) == 0o600)
        }
        // No temporary file is left next to the settings file.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: env.settings.deletingLastPathComponent().path)
        #expect(siblings == ["settings.json"])
    }

    @Test func replacementHasItsModeBeforeTheRename() throws {
        let env = try makeEnv(settings: "{}")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.settings.path)
        var seen: [(path: String, mode: Int?, bytes: Data)] = []
        try AtomicFile.replace(env.settings, with: Data("{\"a\": 1}".utf8), permissions: 0o600) { tmp in
            seen.append((tmp.path, try mode(tmp.path), try Data(contentsOf: tmp)))
            // Not yet renamed: the original is still in place.
            #expect(try read(env.settings) == "{}")
        }
        #expect(seen.count == 1)
        #expect(seen.first?.mode == 0o600)
        #expect(seen.first?.bytes == Data("{\"a\": 1}".utf8))
        #expect(seen.first.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path }
            == env.settings.deletingLastPathComponent().path)
        #expect(try read(env.settings) == "{\"a\": 1}")
        #expect(try mode(env.settings.path) == 0o600)
        #expect(seen.first.map { FileManager.default.fileExists(atPath: $0.path) } == false)
    }

    @Test func failureBeforeTheRenameLeavesTheOriginal() throws {
        let env = try makeEnv(settings: "{\"keep\": true}")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: env.settings.path)
        struct Stop: Error {}
        var tmpPath: String?
        #expect(throws: Stop.self) {
            try AtomicFile.replace(env.settings, with: Data("{}".utf8), permissions: 0o640) { tmp in
                tmpPath = tmp.path
                throw Stop()
            }
        }
        #expect(try read(env.settings) == "{\"keep\": true}")
        #expect(try mode(env.settings.path) == 0o640)
        #expect(tmpPath.map { FileManager.default.fileExists(atPath: $0) } == false)
    }

    @Test func repairNoticesAPathThatDiffersOnlyByWhitespace() throws {
        let old = "/tmp/x/My Apps/Spool.app/Contents/MacOS/spool-statusline"
        let new = "/tmp/x/MyApps/Spool.app/Contents/MacOS/spool-statusline"
        let env = try makeEnv(settings: "{\n  \"theme\": \"dark\"\n}\n", helper: old)
        try env.connector.connect(now: now)
        #expect(env.connector.status() == .connected)
        let moved = ClaudeCodeConnector(settingsURL: env.settings, paths: env.paths, helperPath: new)
        #expect(moved.status() == .needsRepair(currentCommand: old))
        try moved.repair(now: now)
        #expect(try storedCommand(env.settings) == "'\(new)'")
        #expect(moved.status() == .connected)
    }

    @Test func repairKeepsTheEntrysOtherMembers() throws {
        let old = "/old/Spool.app/Contents/MacOS/spool-statusline"
        let text = "{\n  \"theme\": \"dark\",\n"
            + "  \"statusLine\": {\"type\": \"command\", \"command\": \"\(old)\", \"padding\": 2},\n"
            + "  \"model\": \"opus\"\n}\n"
        let env = try makeEnv(settings: text)
        #expect(env.connector.status() == .needsRepair(currentCommand: old))
        try env.connector.repair(now: now)
        #expect(env.connector.status() == .connected)
        let edited = try read(env.settings)
        let entry = try #require(try JSONSerialization.jsonObject(with: Data(edited.utf8)) as? [String: Any])["statusLine"]
            as? [String: Any]
        #expect(entry?["padding"] as? Int == 2)
        #expect(entry?["type"] as? String == "command")
        #expect(try storedCommand(env.settings) == "'\(helper)'")
        // Outside the entry the file is byte for byte what it was.
        #expect(try JSONTopLevelEditor.removing(key: "statusLine", in: edited)
            == JSONTopLevelEditor.removing(key: "statusLine", in: text))
        // Nothing left to do: a second repair writes nothing.
        let backupsAfter = backups(env.paths)
        try env.connector.repair(now: now)
        #expect(backups(env.paths) == backupsAfter)
        #expect(try read(env.settings) == edited)
    }

    @Test func entryWithoutCommandTypeNeedsRepair() throws {
        let env = try makeEnv(settings: "{\"statusLine\": {\"command\": \"'\(helper)'\"}}")
        #expect(env.connector.status() == .needsRepair(currentCommand: helper))
        try env.connector.repair(now: now)
        #expect(env.connector.status() == .connected)
        #expect(!FileManager.default.fileExists(atPath: env.paths.chainState.path))
        // A one-line entry stays on one line.
        #expect(try read(env.settings) == "{\"statusLine\": {\"command\": \"'\(helper)'\", \"type\": \"command\"}}")
    }

    @Test func typeAddedToAMultiLineEntryFollowsItsIndentation() throws {
        let old = "/old/Spool.app/Contents/MacOS/spool-statusline"
        let text = "{\n  \"statusLine\": {\n    \"command\": \"\(old)\",\n    \"padding\": 2\n  }\n}\n"
        let env = try makeEnv(settings: text)
        try env.connector.repair(now: now)
        #expect(try read(env.settings)
            == "{\n  \"statusLine\": {\n    \"command\": \"'\(helper)'\",\n    \"padding\": 2,\n    \"type\": \"command\"\n  }\n}\n")
        #expect(env.connector.status() == .connected)
    }

    @Test func memberDuplicatedInsideTheEntryNamesTheEntry() throws {
        let old = "/old/Spool.app/Contents/MacOS/spool-statusline"
        let text = "{\"statusLine\": {\"type\": \"command\", \"command\": \"\(old)\", \"command\": \"\(old)\"}}"
        let env = try makeEnv(settings: text)
        #expect(throws: SpoolError.duplicateKeyInEntry(entry: "statusLine", key: "command")) {
            try env.connector.repair(now: now)
        }
        #expect(try read(env.settings) == text)
        #expect(backups(env.paths).isEmpty)
    }

    @Test func compoundCommandEndingInTheHelperIsForeign() throws {
        let command = "~/bin/my-line; /tmp/Spool.app/Contents/MacOS/spool-statusline"
        let raw = #"{"type":"command","command":"\#(command)"}"#
        let text = "{\n  \"statusLine\": \(raw),\n  \"theme\": \"dark\"\n}\n"
        let env = try makeEnv(settings: text)
        #expect(env.connector.status() == .notConnected)
        try env.connector.connect(now: now)
        let state = try chain(env.paths)
        #expect(state.previousStatusLine == raw)
        #expect(state.previousCommand == command)
        #expect(env.connector.status() == .connected)
        try env.connector.disconnect(now: now)
        #expect(try read(env.settings) == text)
    }

    @Test func onlyASingleCommandRunningTheHelperIsOurs() {
        let path = "/Applications/Spool.app/Contents/MacOS/spool-statusline"
        for ours in [
            path,
            ClaudeCodeConnector.shellQuoted(path),
            // Shell characters inside single quotes are part of the path.
            ClaudeCodeConnector.shellQuoted("/Apps/A;B|C&D$(E)`F`<G>/Spool.app/Contents/MacOS/spool-statusline"),
            // Written unquoted by an older build: a space splits it, a quote leaves it open.
            "/Applications/My Apps/Spool.app/Contents/MacOS/spool-statusline",
            "/Users/x/Jo's Spool.app/Contents/MacOS/spool-statusline",
        ] {
            #expect(ClaudeCodeConnector.isOurs(ours), "\(ours)")
        }
        for foreign in [
            "~/bin/my-line; \(path)",
            "~/bin/my-line;\(path)",
            "~/bin/my-line && \(path)",
            "~/bin/my-line | \(path)",
            "~/bin/my-line &\(path)",
            "cd /tmp\n\(path)",
            "$(echo \(path))",
            "`echo \(path)`",
            "\"$(dirname x)/spool-statusline\"",
            "\(path) < /dev/null > /tmp/x/spool-statusline",
            "~/bin/my-line",
            "",
        ] {
            #expect(!ClaudeCodeConnector.isOurs(foreign), "\(foreign)")
        }
    }

    @Test func wrappersAroundTheHelperAreForeign() throws {
        let path = "/Applications/Spool.app/Contents/MacOS/spool-statusline"
        let wrappers = ["FOO=1 \(path)", "nice \(path)", "bash \(path)", "/usr/bin/env -i \(path)",
                        "cat /tmp/spool-statusline"]
        for command in wrappers {
            #expect(!ClaudeCodeConnector.isOurs(command), "\(command)")
            let raw = #"{"type":"command","command":"\#(command)"}"#
            let text = "{\n  \"statusLine\": \(raw)\n}\n"
            let env = try makeEnv(settings: text)
            #expect(env.connector.status() == .notConnected)
            try env.connector.connect(now: now)
            #expect(try chain(env.paths).previousCommand == command)
            #expect(env.connector.status() == .connected)
            try env.connector.disconnect(now: now)
            #expect(try read(env.settings) == text)
        }
        // What older builds wrote stays Spool's own, spaces and all.
        #expect(ClaudeCodeConnector.isOurs("/Applications/My Apps/Spool.app/Contents/MacOS/spool-statusline"))
        #expect(ClaudeCodeConnector.isOurs("  /Applications/My Apps/Spool.app/Contents/MacOS/spool-statusline "))
    }

    @Test func duplicateStatusLineIsNeverGuessed() throws {
        let raw = #"{"type":"command","command":"~/bin/my-line"}"#
        let text = "{\"statusLine\": \"first\", \"statusLine\": \(raw)}"
        let env = try makeEnv(settings: text)
        // Claude Code reads the last one.
        #expect(env.connector.status() == .notConnected)
        #expect(throws: SpoolError.duplicateKey("statusLine")) { try env.connector.connect(now: now) }
        #expect(try read(env.settings) == text)
        #expect(backups(env.paths).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.paths.chainState.path))
    }

    @Test func settingsStampChangesOnlyWithTheFile() throws {
        let env = try makeEnv(settings: nil)
        #expect(env.connector.settingsStamp() == nil)
        try FileManager.default.createDirectory(at: env.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: env.settings)
        let first = try #require(env.connector.settingsStamp())
        #expect(env.connector.settingsStamp() == first)
        // Same size, later modification time.
        try Data("[]".utf8).write(to: env.settings)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)],
                                              ofItemAtPath: env.settings.path)
        let second = try #require(env.connector.settingsStamp())
        #expect(second != first)
        // Same modification time, another size.
        try Data("{ }".utf8).write(to: env.settings)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)],
                                              ofItemAtPath: env.settings.path)
        #expect(env.connector.settingsStamp() != second)
        // Connect replaces the file with a rename.
        let beforeConnect = env.connector.settingsStamp()
        try env.connector.connect(now: now)
        #expect(env.connector.settingsStamp() != beforeConnect)
    }

    @Test func standardSettingsURLHonoursEnvOrDefault() {
        let url = ClaudeCodeConnector.standardSettingsURL()
        #expect(url.lastPathComponent == "settings.json")
    }
}
