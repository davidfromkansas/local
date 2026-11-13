import Foundation

/// The one speech model that turns a finished recording into words: Qwen3-ASR-1.7B (Alibaba), 8-bit MLX.
/// Musci-ASR (a leaderboard fine-tune of the same model) was benchmarked on dictation clips and
/// lost, so it isn't offered; see docs/MAC.md.
public enum SpeechModel {
    public static let repo = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
    public static let displayName = "Qwen3-ASR 1.7B"
    public static let approximateDownload = "2.5 GB"
}

/// The local LLM that polishes punctuation, fillers and self-corrections after transcription.
public enum CleanupModelChoice: String, CaseIterable, Codable, Sendable, Identifiable {
    case qwen3_4B = "qwen3-4b-2507"
    case qwen35_4B = "qwen3.5-4b"
    case qwen35_9B = "qwen3.5-9b"

    public var id: String { rawValue }

    public var repo: String {
        switch self {
        case .qwen3_4B: "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        case .qwen35_4B: "mlx-community/Qwen3.5-4B-MLX-4bit"
        case .qwen35_9B: "mlx-community/Qwen3.5-9B-MLX-4bit"
        }
    }

    public var displayName: String {
        switch self {
        case .qwen3_4B: "Qwen3 4B Instruct"
        case .qwen35_4B: "Qwen3.5 4B"
        case .qwen35_9B: "Qwen3.5 9B"
        }
    }

    public var approximateDownload: String {
        switch self {
        case .qwen3_4B: "2.3 GB"
        case .qwen35_4B: "3.0 GB"
        case .qwen35_9B: "5.6 GB"
        }
    }
}

/// Where downloaded models live: ~/Library/Application Support/Taki/Models.
public struct ModelStore: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? URL.applicationSupportDirectory.appending(path: "Taki/Models", directoryHint: .isDirectory)
    }

    public var speechDirectory: URL { root.appending(path: "speech-qwen3", directoryHint: .isDirectory) }

    public func directory(for cleanup: CleanupModelChoice) -> URL {
        root.appending(path: "cleanup-\(cleanup.rawValue)", directoryHint: .isDirectory)
    }

    public var isSpeechModelDownloaded: Bool { hasWeights(speechDirectory) }
    public func isDownloaded(_ cleanup: CleanupModelChoice) -> Bool { hasWeights(directory(for: cleanup)) }

    func hasWeights(_ directory: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return files.contains("config.json") && files.contains { $0.hasSuffix(".safetensors") }
    }
}
