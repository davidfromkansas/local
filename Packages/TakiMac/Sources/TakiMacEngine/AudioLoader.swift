@preconcurrency import AVFoundation

public enum AudioLoader {
    /// Any audio file → 16 kHz mono Float32.
    public static func load16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { return [] }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        let feeder = BufferFeeder(input, then: .endOfStream)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in feeder.next(status) }
        if let error { throw error }
        guard let data = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }
}

/// Hands one buffer to AVAudioConverter, then reports "no more data".
private nonisolated final class BufferFeeder: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    private let end: AVAudioConverterInputStatus
    init(_ buffer: AVAudioPCMBuffer, then end: AVAudioConverterInputStatus) {
        self.buffer = buffer
        self.end = end
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = end
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
