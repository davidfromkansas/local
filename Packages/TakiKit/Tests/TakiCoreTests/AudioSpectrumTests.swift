import Foundation
import Testing
@testable import TakiCore

@Suite struct AudioSpectrumTests {
    private func sine(_ hz: Float, amplitude: Float, count: Int = 1024) -> [Float] {
        (0..<count).map { amplitude * sin(2 * .pi * hz * Float($0) / 16_000) }
    }

    @Test func silenceIsFlat() {
        let analyzer = SpectrumAnalyzer()
        analyzer.append([Float](repeating: 0, count: 1024))
        #expect(analyzer.bands().allSatisfy { $0 == 0 })
    }

    @Test func notEnoughAudioIsFlat() {
        let analyzer = SpectrumAnalyzer()
        analyzer.append(sine(1_000, amplitude: 0.5, count: 100))
        #expect(analyzer.bands() == [Float](repeating: 0, count: SpectrumAnalyzer.bandCount))
    }

    @Test func toneLightsItsBand() {
        let analyzer = SpectrumAnalyzer()
        analyzer.append(sine(300, amplitude: 0.1))
        let low = analyzer.bands()
        analyzer.append(sine(4_000, amplitude: 0.1))
        let high = analyzer.bands()
        let lowPeak = low.indices.max { low[$0] < low[$1] }!
        let highPeak = high.indices.max { high[$0] < high[$1] }!
        #expect(low.count == SpectrumAnalyzer.bandCount)
        #expect(lowPeak < 8)
        #expect(highPeak > 16)
        #expect(low[lowPeak] > 0.5)
    }

    @Test func gainLiftsQuietBands() {
        let analyzer = SpectrumAnalyzer()
        analyzer.append(sine(300, amplitude: 0.003))
        let plain = analyzer.bands().max()!
        let boosted = analyzer.bands(gainDB: 20).max()!
        #expect(boosted > plain + 0.3)
    }

    private func db(_ value: Float) -> Float { pow(10, value / 20) }

    /// 3 s of room noise at -70 dB, then `seconds` of `voice` dB; returns the levels during the voice.
    private func levels(voice: Float, noise: Float = -70, seconds: Float = 1) -> [Float] {
        var meter = VoiceMeter()
        for i in 0..<47 { _ = meter.update(rms: db(noise + (i % 2 == 0 ? 2 : -2)), seconds: 0.064) }
        return (0..<Int(seconds / 0.064)).map { _ in meter.update(rms: db(voice), seconds: 0.064).level }
    }

    @Test func roomNoiseStaysStill() {
        #expect(levels(voice: -69).allSatisfy { $0 == 0 })
    }

    @Test func whisperMovesTheOrb() {
        #expect(levels(voice: -60).first! > 0.4)
    }

    @Test func quietSpeechFillsTheRange() {
        #expect(levels(voice: -46).first! > 0.9)
    }

    @Test func spectrumGainIsCapped() {
        var meter = VoiceMeter()
        #expect(meter.update(rms: db(-80), seconds: 0.064).gainDB == VoiceMeter.maxSpectrumGain)
        #expect(meter.update(rms: db(-10), seconds: 0.064).gainDB == 0)
    }

    @Test func whisperRecordingIsTurnedUp() {
        let soft = sine(300, amplitude: 0.005, count: 16_000)  // -49 dB
        let soft2 = 20 * log10(SpeechLoudness.speechRMS(SpeechLoudness.boost(soft)))
        #expect(abs(soft2 - SpeechLoudness.targetDB) < 1)
        let whisper = sine(300, amplitude: 0.0015, count: 16_000)  // -60 dB: capped at +30
        let whisper2 = 20 * log10(SpeechLoudness.speechRMS(SpeechLoudness.boost(whisper)))
        #expect(abs(whisper2 - (-59.5 + SpeechLoudness.maxGainDB)) < 1)
    }

    @Test func boostNeverClips() {
        var spiky = sine(300, amplitude: 0.001, count: 16_000)
        spiky[100] = 0.5
        #expect(SpeechLoudness.boost(spiky).allSatisfy { abs($0) <= 0.98 })
    }

    @Test func loudRecordingIsUntouched() {
        let loud = sine(300, amplitude: 0.3, count: 16_000)
        #expect(SpeechLoudness.boost(loud) == loud)
    }

    @Test func storeRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = SharedStore(directory: dir)
        store.writeSpectrum([0.1, 0.5, 1])
        #expect(store.readSpectrum() == [0.1, 0.5, 1])
        store.writeSpectrum([])
        #expect(store.readSpectrum().isEmpty)
    }
}
