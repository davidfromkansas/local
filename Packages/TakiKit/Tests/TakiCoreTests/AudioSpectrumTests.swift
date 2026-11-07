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

    @Test func autoGainLiftsQuietSpeechButNotLoud() {
        var quiet = AutoGain()
        #expect(quiet.update(rms: 0.005, seconds: 0.064) > 15)  // -46 dB
        var loud = AutoGain()
        #expect(loud.update(rms: 0.3, seconds: 0.064) == 0)     // -10 dB
    }

    @Test func autoGainIsCappedInSilence() {
        var gain = AutoGain()
        _ = gain.update(rms: 0.01, seconds: 0.1)
        var last: Float = 0
        for _ in 0..<100 { last = gain.update(rms: 0.0001, seconds: 0.1) }
        #expect(last == AutoGain.maxGain)
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
