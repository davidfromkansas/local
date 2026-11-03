import Foundation
import TakiCore
import TakiEngine
import Testing

private final class BundleToken {}

private struct Clip: Decodable {
    let file: String
    let voice: String
    let reference: String
    /// What the cleaned-up text should read like (defaults to `reference`).
    let cleaned: String?
}

/// Runs the `say`-generated clips through the exact app pipeline (VAD → Parakeet → cleanup).
/// Opt-in because it downloads the model (~1 GB) on first run:
/// `TEST_RUNNER_TAKI_ASR_TESTS=1 scripts/build.sh test`
@Suite(.serialized)
struct ASRAccuracyTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["TAKI_ASR_TESTS"] == "1" }

    @Test(.enabled(if: ASRAccuracyTests.enabled), .timeLimit(.minutes(30)))
    func wordErrorRateAndLatency() async throws {
        let bundle = Bundle(for: BundleToken.self)
        let manifest = try #require(bundle.url(forResource: "clips", withExtension: "json"))
        let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: manifest))
        let choice = ASRModelChoice(rawValue: ProcessInfo.processInfo.environment["TAKI_ASR_MODEL"] ?? "") ?? .parakeetUnified

        let engine = TranscriptionEngine()
        let clock = ContinuousClock()
        let prepareTime = try await clock.measure { try await engine.prepare(choice) }
        let pipeline = DictationPipeline(engine: engine)

        var lines = [
            "| Clip | Audio | Latency | Raw WER | Final WER | Final text |",
            "|---|---|---|---|---|---|",
        ]
        var rawTotal = 0.0
        var finalTotal = 0.0
        for clip in clips {
            let url = try #require(bundle.url(forResource: clip.file, withExtension: nil))
            let samples = try AudioFile.load16kMono(url)
            var output: DictationOutput?
            let latency = try await clock.measure { output = try await pipeline.run(samples) }
            let result = try #require(output)
            let rawWER = WordErrorRate.compute(reference: clip.reference, hypothesis: result.rawText)
            let finalWER = WordErrorRate.compute(reference: clip.cleaned ?? clip.reference, hypothesis: result.text)
            rawTotal += rawWER
            finalTotal += finalWER
            lines.append(String(
                format: "| %@ | %.1fs | %.2fs | %.1f%% | %.1f%% | %@ |",
                clip.file, result.audioSeconds, latency.seconds, rawWER * 100, finalWER * 100, result.text
            ))
        }
        let count = Double(clips.count)
        lines.append(String(format: "| **Mean** | | | **%.1f%%** | **%.1f%%** | |", rawTotal / count * 100, finalTotal / count * 100))
        lines.append("")
        lines.append(String(format: "Model: %@ · load/compile: %.1fs · simulator CPU (no Neural Engine) — not representative of iPhone speed.", choice.displayName, prepareTime.seconds))
        let report = lines.joined(separator: "\n")
        for line in lines { print("TAKI-ASR| \(line)") }
        try? report.write(to: URL.temporaryDirectory.appending(path: "taki-asr-report.md"), atomically: true, encoding: .utf8)

        #expect(rawTotal / count < 0.15)
    }

    /// Plays every clip back to back (with short pauses) through the live transcriber the way the
    /// hot mic does: small chunks, a live pass after each, then the final pass. Long enough to make
    /// the transcriber cut and keep earlier speech, so this checks the stitched text stays accurate.
    @Test(.enabled(if: ASRAccuracyTests.enabled), .timeLimit(.minutes(30)))
    func liveTranscriptionMatchesBatch() async throws {
        let bundle = Bundle(for: BundleToken.self)
        let manifest = try #require(bundle.url(forResource: "clips", withExtension: "json"))
        let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: manifest))
        let engine = TranscriptionEngine()
        try await engine.prepare(.parakeetUnified)

        var audio: [Float] = []
        for clip in clips {
            let url = try #require(bundle.url(forResource: clip.file, withExtension: nil))
            audio += try AudioFile.load16kMono(url)
            audio += [Float](repeating: 0, count: 12_800)  // 0.8 s pause
        }
        let reference = clips.map(\.reference).joined(separator: " ")

        let live = LiveTranscriber(engine: engine)
        let chunk = 4_800  // 0.3 s
        var passes = 0
        var lastPartial = ""
        for start in stride(from: 0, to: audio.count, by: chunk) {
            await live.append(Array(audio[start..<min(audio.count, start + chunk)]))
            if start / chunk % 3 == 0 {  // a pass every ~0.9 s of audio, like a slow device
                lastPartial = try await live.transcribe()
                passes += 1
            }
        }
        let clock = ContinuousClock()
        var final = ""
        let finalLatency = try await clock.measure { final = try await live.transcribe(final: true) }

        let liveWER = WordErrorRate.compute(reference: reference, hypothesis: final)
        let batchWER = WordErrorRate.compute(reference: reference, hypothesis: try await engine.transcribe(audio))
        print(String(
            format: "TAKI-ASR| live: %.1fs audio, %d passes, final pass %.2fs, live WER %.1f%%, batch WER %.1f%%",
            Double(audio.count) / 16_000, passes, finalLatency.seconds, liveWER * 100, batchWER * 100
        ))
        print("TAKI-ASR| last live text: \(lastPartial)")
        print("TAKI-ASR| final text: \(final)")
        #expect(liveWER < batchWER + 0.05)
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
