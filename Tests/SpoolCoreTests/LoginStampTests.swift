import Foundation
import Testing
@testable import SpoolCore

struct LoginStampTests {
    let now = Date(timeIntervalSince1970: 1_794_320_000)

    /// Attribute output of `security find-generic-password -s <service> -a <account>` (no `-w`),
    /// captured from a throwaway item.
    let attributes = """
    keychain: "/Users/test/Library/Keychains/login.keychain-db"
    version: 512
    class: "genp"
    attributes:
        0x00000007 <blob>="spool-probe"
        "acct"<blob>="test"
        "cdat"<timedate>=0x32303236313131303230323534305A00  "20261110202540Z\\000"
        "mdat"<timedate>=0x32303236313131303230333031355A00  "20261110203015Z\\000"
        "svce"<blob>="spool-probe"
    """

    @Test func keychainModificationIsReadFromAttributes() {
        #expect(LoginStamp.keychainModified(fromAttributes: Data(attributes.utf8)) == "20261110203015Z")
        let noDate = attributes.split(separator: "\n").filter { !$0.contains("mdat") }.joined(separator: "\n")
        #expect(LoginStamp.keychainModified(fromAttributes: Data(noDate.utf8)) == nil)
        #expect(LoginStamp.keychainModified(fromAttributes: Data()) == nil)
    }

    @Test func pauseHoldsReadsUntilTheIntervalOrAChangedLogin() {
        let stamp = LoginStamp(keychainModified: "20261110203015Z", fileModified: nil)
        var pause = ExpiredLoginPause()
        #expect(pause.allowsRead(now: now, stamp: stamp))
        pause.record(now: now, stamp: stamp)
        #expect(!pause.allowsRead(now: now.addingTimeInterval(1), stamp: stamp))
        #expect(!pause.allowsRead(now: now.addingTimeInterval(899), stamp: stamp))
        #expect(pause.allowsRead(now: now.addingTimeInterval(900), stamp: stamp))
        // Claude Code rewrote its Keychain item, or the fallback file.
        #expect(pause.allowsRead(now: now.addingTimeInterval(1), stamp: LoginStamp(keychainModified: "20261110204000Z")))
        #expect(pause.allowsRead(now: now.addingTimeInterval(1),
                                 stamp: LoginStamp(keychainModified: "20261110203015Z", fileModified: now)))
        pause.clear()
        #expect(pause.allowsRead(now: now.addingTimeInterval(1), stamp: stamp))
    }

    @Test func repeatedRefusalBacksOffAndANewLoginGoesAheadAtOnce() {
        let a = LoginStamp(keychainModified: "20261117140000Z")
        let b = LoginStamp(keychainModified: "20261117150000Z")
        var refusals = LoginRefusals()
        var gate = FetchGate()
        #expect(!refusals.openForNewLogin(stamp: a, gate: &gate))

        // First refusal of login a: pause only, the gate stays as it was.
        #expect(!refusals.recordRefusal(stamp: a, now: now, gate: &gate))
        #expect(gate == FetchGate())
        #expect(!refusals.openForNewLogin(stamp: a, gate: &gate))

        // Refused again under the same login: the backoff grows as for any failure.
        #expect(refusals.recordRefusal(stamp: a, now: now, gate: &gate))
        #expect(gate.nextAttempt == now.addingTimeInterval(900))
        #expect(refusals.recordRefusal(stamp: a, now: now, gate: &gate))
        #expect(gate.nextAttempt == now.addingTimeInterval(1_800))
        #expect(!refusals.openForNewLogin(stamp: a, gate: &gate))
        #expect(!gate.allows(now: now.addingTimeInterval(60)))

        // Claude Code wrote a new login: the next attempt goes ahead now, the backoff dropped.
        #expect(refusals.openForNewLogin(stamp: b, gate: &gate))
        #expect(gate.allows(now: now.addingTimeInterval(60)))
        gate.recordFailure(now: now)
        #expect(gate.nextAttempt == now.addingTimeInterval(900))
        // A refusal of the new login is its first.
        var fresh = FetchGate()
        #expect(!refusals.recordRefusal(stamp: b, now: now, gate: &fresh))
        #expect(fresh == FetchGate())

        // Any other outcome forgets the refusals.
        refusals.clear()
        #expect(!refusals.openForNewLogin(stamp: a, gate: &gate))
        #expect(!refusals.recordRefusal(stamp: b, now: now, gate: &fresh))
    }

    @Test func refusedClaudeLoginWaitsForANewLoginInsteadOfBackingOff() {
        for code in [401, 403] {
            #expect(FailedRequest.action(forStatus: code, provider: .claude) == .pauseUntilLoginChanges)
            // Codex has no login stamp to watch.
            #expect(FailedRequest.action(forStatus: code, provider: .codex) == .backOff)
        }
        for code in [400, 404, 500, 502, 503] {
            #expect(FailedRequest.action(forStatus: code, provider: .claude) == .backOff)
            #expect(FailedRequest.action(forStatus: code, provider: .codex) == .backOff)
        }
    }
}
