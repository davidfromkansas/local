import Foundation

/// File-based state in the App Group container, shared by the app and the keyboard.
/// Files (not UserDefaults) so cross-process reads are never stale.
public struct SharedStore: Sendable {
    public static let defaultAppGroup = "group.com.davidfromkansas.taki"

    /// App Group id from Info.plist (`TakiAppGroup`, set from the xcconfig), falling back to the default.
    public static var appGroupID: String {
        (Bundle.main.object(forInfoDictionaryKey: "TakiAppGroup") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? defaultAppGroup
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `nil` when the App Group entitlement is missing (unsigned build).
    public init?(appGroup: String = SharedStore.appGroupID) {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return nil
        }
        self.init(directory: container.appending(path: "ipc", directoryHint: .isDirectory))
    }

    private var snapshotURL: URL { directory.appending(path: "session.json") }
    private var requestURL: URL { directory.appending(path: "request.json") }
    private var resultURL: URL { directory.appending(path: "result.json") }
    private var partialURL: URL { directory.appending(path: "partial.json") }
    private var levelURL: URL { directory.appending(path: "level.bin") }
    private var spectrumURL: URL { directory.appending(path: "spectrum.bin") }

    /// DEBUG-only audio feed location (used instead of the mic on machines without one).
    public var debugFeedURL: URL { directory.appending(path: "debug-feed.wav") }

    public func write(_ snapshot: SessionSnapshot) { write(snapshot, to: snapshotURL) }
    public func readSnapshot() -> SessionSnapshot? { read(SessionSnapshot.self, from: snapshotURL) }

    public func write(_ request: DictationRequest) { write(request, to: requestURL) }
    public func readRequest() -> DictationRequest? { read(DictationRequest.self, from: requestURL) }

    public func write(_ result: DictationResult) { write(result, to: resultURL) }
    public func readResult() -> DictationResult? { read(DictationResult.self, from: resultURL) }

    /// Live text while capturing; same shape as the final result.
    public func writePartial(_ partial: DictationResult) { write(partial, to: partialURL) }
    public func readPartial() -> DictationResult? { read(DictationResult.self, from: partialURL) }

    /// Normalized input level 0…1 while capturing.
    public func writeLevel(_ level: Float) {
        var value = level
        let data = Data(bytes: &value, count: MemoryLayout<Float>.size)
        try? data.write(to: levelURL, options: .atomic)
    }

    public func readLevel() -> Float {
        guard let data = try? Data(contentsOf: levelURL), data.count == MemoryLayout<Float>.size else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    }

    /// `SpectrumAnalyzer` bands while capturing (empty when idle).
    public func writeSpectrum(_ bands: [Float]) {
        let data = bands.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: spectrumURL, options: .atomic)
    }

    public func readSpectrum() -> [Float] {
        guard let data = try? Data(contentsOf: spectrumURL), data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? IPCCodec.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? IPCCodec.decode(type, from: data)
    }
}
