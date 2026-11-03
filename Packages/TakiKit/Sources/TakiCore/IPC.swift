import Foundation

/// Signals exchanged between the keyboard extension and the main app via the Darwin notify center.
/// Darwin notifications carry no payload; data travels through `SharedStore` files.
public enum TakiSignal: String, CaseIterable, Sendable {
    /// Keyboard → app: start capturing (session must already be armed).
    case start
    /// Keyboard → app: stop capturing and transcribe.
    case stop
    /// Keyboard → app: stop capturing and discard the audio.
    case cancel
    /// App → keyboard: a new `DictationResult` is in the shared store.
    case resultReady
    /// App → keyboard: the `SessionSnapshot` changed.
    case stateChanged

    public static let prefix = "com.davidfromkansas.taki."

    public var notificationName: String { Self.prefix + rawValue }

    public init?(notificationName: String) {
        guard notificationName.hasPrefix(Self.prefix) else { return nil }
        self.init(rawValue: String(notificationName.dropFirst(Self.prefix.count)))
    }
}

/// Session phase as seen by both processes.
public enum SessionPhase: String, Codable, Sendable {
    /// No hot-mic session. The keyboard must open the app (`taki://start`) first.
    case inactive
    /// Mic engine running, buffers discarded. Keeps the app alive in the background.
    case armed
    /// Buffers accumulating for a dictation.
    case capturing
    /// Running ASR + cleanup.
    case processing
}

/// Written by the app whenever the session changes; read by the keyboard.
public struct SessionSnapshot: Codable, Sendable, Equatable {
    public var phase: SessionPhase
    /// When an armed session expires. `nil` while capturing/processing (no expiry then).
    public var expiresAt: Date?
    public var updatedAt: Date
    /// Short human-readable error from the last dictation, if any.
    public var errorMessage: String?

    public init(phase: SessionPhase, expiresAt: Date? = nil, updatedAt: Date = .now, errorMessage: String? = nil) {
        self.phase = phase
        self.expiresAt = expiresAt
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
    }

    public static let inactive = SessionSnapshot(phase: .inactive)
}

/// Written by the keyboard right before posting `.start`, so the result can be matched to its request.
public struct DictationRequest: Codable, Sendable, Equatable {
    public var id: UUID
    public var createdAt: Date

    public init(id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id
        self.createdAt = createdAt
    }
}

/// Written by the app after a dictation finishes; the keyboard inserts `text`.
public struct DictationResult: Codable, Sendable, Equatable {
    public var requestID: UUID?
    public var text: String
    public var createdAt: Date

    public init(requestID: UUID?, text: String, createdAt: Date = .now) {
        self.requestID = requestID
        self.text = text
        self.createdAt = createdAt
    }
}

/// JSON encoding used for every IPC file. One place so both processes agree.
public enum IPCCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }
}

/// What the keyboard's mic button should show.
public enum KeyboardUIState: Sendable, Equatable {
    case notReady
    case ready
    case recording
    case processing

    public init(snapshot: SessionSnapshot?, now: Date = .now) {
        guard let snapshot else { self = .notReady; return }
        switch snapshot.phase {
        case .inactive:
            self = .notReady
        case .armed:
            if let expiresAt = snapshot.expiresAt, expiresAt <= now {
                self = .notReady
            } else {
                self = .ready
            }
        case .capturing:
            self = .recording
        case .processing:
            self = .processing
        }
    }
}
