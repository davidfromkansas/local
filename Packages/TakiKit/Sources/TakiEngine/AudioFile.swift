import FluidAudio
import Foundation

public enum AudioFile {
    /// Any audio file → 16 kHz mono Float32 samples (what every Taki model expects).
    public static func load16kMono(_ url: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(url)
    }
}
