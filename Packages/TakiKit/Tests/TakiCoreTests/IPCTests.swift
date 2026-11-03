import Foundation
import Testing
@testable import TakiCore

struct IPCTests {
    @Test func `signals round-trip through notification names`() {
        for signal in TakiSignal.allCases {
            #expect(TakiSignal(notificationName: signal.notificationName) == signal)
            #expect(signal.notificationName.hasPrefix("com.davidfromkansas.taki."))
        }
        #expect(TakiSignal(notificationName: "com.other.start") == nil)
    }

    @Test func `snapshot and result encode and decode`() throws {
        let snapshot = SessionSnapshot(
            phase: .armed, expiresAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 900),
            errorMessage: nil
        )
        let decoded = try IPCCodec.decode(SessionSnapshot.self, from: IPCCodec.encode(snapshot))
        #expect(decoded == snapshot)

        let result = DictationResult(requestID: UUID(), text: "Hello, world.", createdAt: Date(timeIntervalSince1970: 5))
        #expect(try IPCCodec.decode(DictationResult.self, from: IPCCodec.encode(result)) == result)

        let json = String(decoding: try IPCCodec.encode(snapshot), as: UTF8.self)
        #expect(json.contains("\"phase\":\"armed\""))
    }

    @Test func `shared store round-trips through files`() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SharedStore(directory: dir)
        #expect(store.readSnapshot() == nil)
        #expect(store.readLevel() == 0)

        let request = DictationRequest(createdAt: Date(timeIntervalSince1970: 1_234))
        store.write(request)
        store.write(SessionSnapshot(phase: .capturing))
        store.write(DictationResult(requestID: request.id, text: "Hi"))
        store.writeLevel(0.42)

        #expect(store.readRequest() == request)
        #expect(store.readSnapshot()?.phase == .capturing)
        #expect(store.readResult()?.requestID == request.id)
        #expect(store.readLevel() == 0.42)
    }

    @Test func `keyboard UI state derives from snapshot`() {
        let now = Date(timeIntervalSince1970: 100)
        #expect(KeyboardUIState(snapshot: nil, now: now) == .notReady)
        #expect(KeyboardUIState(snapshot: .inactive, now: now) == .notReady)
        #expect(KeyboardUIState(snapshot: .init(phase: .armed, expiresAt: now.addingTimeInterval(10)), now: now) == .ready)
        #expect(KeyboardUIState(snapshot: .init(phase: .armed, expiresAt: now.addingTimeInterval(-1)), now: now) == .notReady)
        #expect(KeyboardUIState(snapshot: .init(phase: .armed, expiresAt: nil), now: now) == .ready)
        #expect(KeyboardUIState(snapshot: .init(phase: .capturing), now: now) == .recording)
        #expect(KeyboardUIState(snapshot: .init(phase: .processing), now: now) == .processing)
    }
}
