import Foundation
import Testing
@testable import SpoolCore

struct ClaudeOAuthTests {
    let now = Date(timeIntervalSince1970: 1_794_320_000)

    @Test func credentialsParse() throws {
        let c = try ClaudeCredentials.parse(fixture("claude-credentials"))
        #expect(c.accessToken == "test-at")
        #expect(c.expiresAt == Date(timeIntervalSince1970: 1_794_330_000))
        #expect(c.planLabel == "Max 5x")
        let pro = #"{"claudeAiOauth":{"accessToken":"a","expiresAt":1,"subscriptionType":"pro"}}"#
        #expect(try ClaudeCredentials.parse(Data(pro.utf8)).planLabel == "Pro")
        let bare = #"{"claudeAiOauth":{"accessToken":"a","expiresAt":1}}"#
        #expect(try ClaudeCredentials.parse(Data(bare.utf8)).planLabel == nil)
        #expect(throws: SpoolError.missingField("claudeAiOauth")) {
            try ClaudeCredentials.parse(Data("{}".utf8))
        }
    }

    @Test func keychainOutputParses() throws {
        let json = try fixture("claude-credentials")
        let expected = try ClaudeCredentials.parse(json)
        #expect(try ClaudeCredentials.parse(keychainOutput: json + Data("\n".utf8)) == expected)
        let hex = json.map { String(format: "%02x", $0) }.joined() + "\n"
        #expect(try ClaudeCredentials.parse(keychainOutput: Data(hex.utf8)) == expected)
        #expect(throws: SpoolError.malformedJSON) {
            try ClaudeCredentials.parse(keychainOutput: Data("not json\n".utf8))
        }
        #expect(throws: SpoolError.malformedJSON) {
            try ClaudeCredentials.parse(keychainOutput: Data("abc\n".utf8))
        }
    }

    @Test func keychainServiceName() {
        #expect(ClaudeCredentials.keychainService(configDirectory: nil) == "Claude Code-credentials")
        #expect(ClaudeCredentials.keychainService(configDirectory: "") == "Claude Code-credentials")
        // printf '%s' /Users/test/.claude-work | shasum -a 256 | cut -c1-8
        #expect(ClaudeCredentials.keychainService(configDirectory: "/Users/test/.claude-work")
            == "Claude Code-credentials-03abf0ee")
    }

    @Test func flatKeysMapToKinds() throws {
        let ws = try ClaudeOAuthUsage.windows(from: fixture("claude-oauth-flat"), observedAt: now)
        #expect(ws.count == 3)
        func pct(_ k: WindowKind) -> Double? { ws.first { $0.kind == k }?.usedPercent }
        #expect(pct(.session) == 62)
        #expect(pct(.weekly) == 14)
        #expect(pct(.weeklyModel("Opus")) == 8)
        #expect(pct(.weeklyModel("Sonnet")) == nil)
        #expect(ws.allSatisfy { $0.source == .oauth && $0.provider == .claude && $0.observedAt == now })
        #expect(ws.first { $0.kind == .session }?.length == 18_000)
        #expect(ws.first { $0.kind == .weekly }?.length == 604_800)
    }

    @Test func limitsArrayIsPreferred() throws {
        let ws = try ClaudeOAuthUsage.windows(from: fixture("claude-oauth-limits"), observedAt: now)
        #expect(ws.count == 3)
        #expect(ws.contains { $0.kind == .weeklyModel("Fable") && $0.usedPercent == 8 })
        #expect(!ws.contains { $0.kind == .weeklyModel("Opus") })
    }

    @Test func limitsWithoutUsableEntriesFallBackToFlatKeys() throws {
        let json = #"""
        {"five_hour":{"utilization":62,"resets_at":"2026-11-10T17:30:00Z"},
         "seven_day":{"utilization":14,"resets_at":"2026-11-14T09:00:00Z"},
         "limits":[{"kind":"monthly_credits","percent":3,"resets_at":"2026-12-01T00:00:00Z"},
                   {"kind":"weekly_scoped","percent":8,"resets_at":"2026-11-14T09:00:00Z"},
                   {"kind":"session","percent":62}]}
        """#
        let ws = try ClaudeOAuthUsage.windows(from: Data(json.utf8), observedAt: now)
        #expect(ws.map(\.kind) == [.session, .weekly])
        #expect(ws.map(\.usedPercent) == [62, 14])
    }

    @Test func resetsAtAsEpochSeconds() throws {
        let flat = #"{"five_hour":{"utilization":5,"resets_at":1794340800},"seven_day":{"utilization":6,"resets_at":1794650400.5}}"#
        let ws = try ClaudeOAuthUsage.windows(from: Data(flat.utf8), observedAt: now)
        #expect(ws.map(\.resetsAt) == [Date(timeIntervalSince1970: 1_794_340_800), Date(timeIntervalSince1970: 1_794_650_400.5)])
        let limits = #"{"limits":[{"kind":"session","percent":7,"resets_at":1794340800}]}"#
        let lw = try ClaudeOAuthUsage.windows(from: Data(limits.utf8), observedAt: now)
        #expect(lw.map(\.resetsAt) == [Date(timeIntervalSince1970: 1_794_340_800)])
        // A boolean is not a time.
        let odd = #"{"five_hour":{"utilization":5,"resets_at":true}}"#
        #expect(try ClaudeOAuthUsage.windows(from: Data(odd.utf8), observedAt: now).isEmpty)
    }

    @Test func isoDatesWithAndWithoutFraction() throws {
        func resets(_ s: String) throws -> Date {
            let json = #"{"five_hour":{"utilization":1,"resets_at":"\#(s)"}}"#
            return try #require(ClaudeOAuthUsage.windows(from: Data(json.utf8), observedAt: now).first).resetsAt
        }
        let a = try resets("2026-11-10T17:30:00Z")
        #expect(try resets("2026-11-10T17:30:00.000+00:00") == a)
        #expect(try resets("2026-11-10T17:30:00.000000Z") == a)
        #expect(try resets("2026-11-10T17:30:00+00:00") == a)
    }

    @Test func requestHeaders() {
        let r = UsageRequests.claude(token: "test-at")
        #expect(r.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(r.httpMethod == "GET")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer test-at")
        #expect(r.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(r.value(forHTTPHeaderField: "Accept") == "application/json")
    }
}
