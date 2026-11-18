import Foundation
import Testing
@testable import SpoolCore

struct CodexTests {
    let now = Date(timeIntervalSince1970: 1_794_320_000)

    @Test func authParse() throws {
        let a = try CodexAuth.parse(fixture("codex-auth"))
        #expect(a.accessToken == "at-test")
        #expect(a.accountId == "acc-123")
        #expect(throws: SpoolError.missingField("tokens")) {
            try CodexAuth.parse(Data(#"{"auth_mode":"apikey"}"#.utf8))
        }
    }

    @Test func keychainOutputParses() throws {
        let json = try fixture("codex-auth")
        let expected = try CodexAuth.parse(json)
        #expect(try CodexAuth.parse(keychainOutput: json + Data("\n".utf8)) == expected)
        let hex = json.map { String(format: "%02x", $0) }.joined() + "\n"
        #expect(try CodexAuth.parse(keychainOutput: Data(hex.utf8)) == expected)
        #expect(throws: SpoolError.missingField("tokens")) {
            try CodexAuth.parse(keychainOutput: Data("{\"auth_mode\":\"apikey\"}\n".utf8))
        }
    }

    @Test func keychainAccountName() {
        // printf '%s' /Users/test/.codex | shasum -a 256 | cut -c1-16
        #expect(CodexAuth.keychainAccount(codexHome: "/Users/test/.codex") == "cli|d446e73b91d0fe9e")
    }

    @Test func usageMapsWindows() throws {
        let (ws, plan) = try CodexUsage.parse(fixture("codex-usage"), observedAt: now)
        #expect(plan == "plus")
        #expect(ws.count == 2)
        let s = try #require(ws.first { $0.kind == .session })
        #expect(s.usedPercent == 40 && s.length == 18_000)
        #expect(s.resetsAt == Date(timeIntervalSince1970: 1_794_327_000))
        let w = try #require(ws.first { $0.kind == .weekly })
        #expect(w.usedPercent == 12 && w.length == 604_800)
        #expect(ws.allSatisfy { $0.source == .codexAPI && $0.provider == .codex })
    }

    @Test func noSecondaryGivesSessionOnly() throws {
        let (ws, _) = try CodexUsage.parse(fixture("codex-usage-no-secondary"), observedAt: now)
        #expect(ws.map(\.kind) == [.session])
    }

    @Test func requestHeaders() {
        let r = UsageRequests.codex(CodexAuth(accessToken: "at-test", accountId: "acc-123"))
        #expect(r.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(r.httpMethod == "GET")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer at-test")
        #expect(r.value(forHTTPHeaderField: "chatgpt-account-id") == "acc-123")
    }
}
