import Foundation
import TakiMacEngine

/// `Taki --bench [--cleanup qwen3-4b-2507,...] [--out report.md] <clip dir>...`
/// Each clip dir holds WAVs plus `clips.json` ([{file, reference}]). Prints a Markdown report.
struct BenchCommand {
    var sets: [URL] = []
    var cleanup: [CleanupModelChoice] = CleanupModelChoice.allCases
    var output: URL?

    init?(arguments: [String]) {
        guard let start = arguments.firstIndex(of: "--bench") else { return nil }
        var args = arguments[(start + 1)...].makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--cleanup": cleanup = (args.next() ?? "").split(separator: ",").compactMap { CleanupModelChoice(rawValue: String($0)) }
            case "--out": output = args.next().map { URL(filePath: $0) }
            default: sets.append(URL(filePath: arg, directoryHint: .isDirectory))
            }
        }
    }

    func run() async {
        do {
            let report = try await Bench.run(sets: sets, cleanup: cleanup) { line in
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
            print(report)
            if let output { try report.write(to: output, atomically: true, encoding: .utf8) }
        } catch {
            FileHandle.standardError.write(Data("Bench failed: \(error)\n".utf8))
        }
    }
}
