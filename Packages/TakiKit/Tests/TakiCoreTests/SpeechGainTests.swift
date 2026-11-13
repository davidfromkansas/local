import Foundation
import Testing
@testable import TakiCore

struct SpeechGainTests {
    func tone(seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    @Test func `lifts a whisper and trims the silence around it`() {
        let silence = [Float](repeating: 0, count: 16_000)
        let whisper = tone(seconds: 1, amplitude: 0.004)  // about -51 dBFS
        let out = SpeechGain.prepare(silence + whisper + silence)
        #expect(out.count < 16_000 * 2)
        #expect(out.count >= 16_000)
        #expect(SpeechGain.rms(out[...]) > 0.05)
    }

    @Test func `leaves loud speech alone`() {
        let loud = tone(seconds: 1, amplitude: 0.5)
        let out = SpeechGain.prepare(loud)
        #expect(abs((out.max() ?? 0) - 0.5) < 0.01)
    }

    @Test func `silence is empty`() {
        #expect(SpeechGain.prepare([Float](repeating: 0, count: 32_000)).isEmpty)
        #expect(SpeechGain.prepare([]).isEmpty)
    }
}

extension SpeechGainTests {
    @Test func `keeps the quiet end of a very quiet recording`() {
        let silence = [Float](repeating: 0, count: 8_000)
        let speech = tone(seconds: 1, amplitude: 0.0015) + tone(seconds: 1, amplitude: 0.0004)  // -57 then -68 dBFS
        let out = SpeechGain.prepare(silence + speech + silence)
        #expect(out.count >= 32_000)
    }
}
