import Foundation
import Testing
@testable import TakiCore

struct SessionMachineTests {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func `full dictation cycle`() {
        var machine = SessionMachine(idleTimeout: 300)
        #expect(machine.handle(.activate(now: t0)) == .startEngine)
        #expect(machine.phase == .armed)
        #expect(machine.expiresAt == t0.addingTimeInterval(300))

        #expect(machine.handle(.startCapture(now: t0.addingTimeInterval(10))) == .beginCapture)
        #expect(machine.phase == .capturing)
        #expect(machine.expiresAt == nil)

        // No expiry while capturing, even long after the idle timeout.
        #expect(machine.handle(.tick(now: t0.addingTimeInterval(1_000))) == .none)
        #expect(machine.phase == .capturing)

        #expect(machine.handle(.stopCapture) == .finishCapture)
        #expect(machine.phase == .processing)

        let done = t0.addingTimeInterval(1_002)
        #expect(machine.handle(.processingFinished(now: done)) == .none)
        #expect(machine.phase == .armed)
        #expect(machine.expiresAt == done.addingTimeInterval(300))
    }

    @Test func `armed session expires after idle timeout`() {
        var machine = SessionMachine(idleTimeout: 60)
        machine.handle(.activate(now: t0))
        #expect(machine.handle(.tick(now: t0.addingTimeInterval(59))) == .none)
        #expect(machine.handle(.tick(now: t0.addingTimeInterval(60))) == .stopEngine)
        #expect(machine.phase == .inactive)
    }

    @Test func `start after expiry ends the session instead of capturing`() {
        var machine = SessionMachine(idleTimeout: 60)
        machine.handle(.activate(now: t0))
        #expect(machine.handle(.startCapture(now: t0.addingTimeInterval(61))) == .stopEngine)
        #expect(machine.phase == .inactive)
    }

    @Test func `re-activation extends the session`() {
        var machine = SessionMachine(idleTimeout: 60)
        machine.handle(.activate(now: t0))
        #expect(machine.handle(.activate(now: t0.addingTimeInterval(50))) == .extended)
        #expect(machine.expiresAt == t0.addingTimeInterval(110))
    }

    @Test func `cancel discards capture and re-arms`() {
        var machine = SessionMachine(idleTimeout: 60)
        machine.handle(.activate(now: t0))
        machine.handle(.startCapture(now: t0))
        #expect(machine.handle(.cancelCapture(now: t0.addingTimeInterval(5))) == .discardCapture)
        #expect(machine.phase == .armed)
        #expect(machine.expiresAt == t0.addingTimeInterval(65))
    }

    @Test func `ignores out-of-order events`() {
        var machine = SessionMachine()
        #expect(machine.handle(.startCapture(now: t0)) == .none)
        #expect(machine.handle(.stopCapture) == .none)
        #expect(machine.handle(.end) == .none)
        machine.handle(.activate(now: t0))
        #expect(machine.handle(.stopCapture) == .none)
        #expect(machine.handle(.processingFinished(now: t0)) == .none)
        #expect(machine.phase == .armed)
    }

    @Test func `zero timeout never expires`() {
        var machine = SessionMachine(idleTimeout: 0)
        machine.handle(.activate(now: t0))
        #expect(machine.expiresAt == nil)
        #expect(machine.handle(.tick(now: t0.addingTimeInterval(1_000_000))) == .none)
        #expect(machine.handle(.end) == .stopEngine)
        #expect(machine.phase == .inactive)
    }
}
