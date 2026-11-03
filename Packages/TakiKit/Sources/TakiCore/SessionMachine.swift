import Foundation

/// Pure hot-mic session state machine. The app's audio controller performs the returned `Effect`s.
///
///     inactive ──activate──▶ armed ──start──▶ capturing ──stop──▶ processing ──finished──▶ armed
///        ▲                     │  ▲              │                                        │
///        └──── timeout/end ────┘  └─── cancel ───┘                                        │
///                                                                       (fresh idle timer)◀┘
public struct SessionMachine: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case activate(now: Date)
        case startCapture(now: Date)
        case stopCapture
        case cancelCapture(now: Date)
        case processingFinished(now: Date)
        case tick(now: Date)
        case end
    }

    public enum Effect: Sendable, Equatable {
        /// Configure the audio session and start the engine in armed mode.
        case startEngine
        /// Session already running; expiry pushed out.
        case extended
        /// Flip the tap to accumulate samples.
        case beginCapture
        /// Stop accumulating and run ASR + cleanup on what was captured.
        case finishCapture
        /// Stop accumulating and throw the samples away.
        case discardCapture
        /// Stop the engine and deactivate the audio session.
        case stopEngine
        /// Nothing to do.
        case none
    }

    public private(set) var phase: SessionPhase = .inactive
    public private(set) var expiresAt: Date?
    /// Idle time before an armed session ends. `0` means never.
    public var idleTimeout: TimeInterval

    public init(idleTimeout: TimeInterval = 300) {
        self.idleTimeout = idleTimeout
    }

    public var snapshot: SessionSnapshot {
        SessionSnapshot(phase: phase, expiresAt: expiresAt)
    }

    private func expiry(from now: Date) -> Date? {
        idleTimeout > 0 ? now.addingTimeInterval(idleTimeout) : nil
    }

    private func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    @discardableResult
    public mutating func handle(_ event: Event) -> Effect {
        switch (phase, event) {
        case (.inactive, .activate(let now)):
            phase = .armed
            expiresAt = expiry(from: now)
            return .startEngine

        case (.armed, .activate(let now)):
            expiresAt = expiry(from: now)
            return .extended

        case (.armed, .startCapture(let now)):
            if isExpired(at: now) {
                phase = .inactive
                expiresAt = nil
                return .stopEngine
            }
            phase = .capturing
            expiresAt = nil
            return .beginCapture

        case (.capturing, .stopCapture):
            phase = .processing
            return .finishCapture

        case (.capturing, .cancelCapture(let now)):
            phase = .armed
            expiresAt = expiry(from: now)
            return .discardCapture

        case (.processing, .processingFinished(let now)):
            phase = .armed
            expiresAt = expiry(from: now)
            return .none

        case (.armed, .tick(let now)) where isExpired(at: now):
            phase = .inactive
            expiresAt = nil
            return .stopEngine

        case (.inactive, .end):
            return .none

        case (_, .end):
            phase = .inactive
            expiresAt = nil
            return .stopEngine

        default:
            return .none
        }
    }
}
