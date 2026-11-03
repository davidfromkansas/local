import Foundation

/// Thin wrapper over the Darwin notify center, the only cross-process signal a keyboard extension can send.
public enum DarwinNotifications {
    public static func post(_ signal: TakiSignal) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(signal.notificationName as CFString),
            nil, nil, true
        )
    }

    /// Stream of the given signals. Observation stops when the stream is cancelled.
    public static func signals(_ signals: [TakiSignal]) -> AsyncStream<TakiSignal> {
        AsyncStream { continuation in
            let box = ObserverBox(continuation: continuation)
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            let pointer = Unmanaged.passUnretained(box).toOpaque()
            for signal in signals {
                CFNotificationCenterAddObserver(
                    center, pointer,
                    { _, observer, name, _, _ in
                        guard let observer, let raw = name?.rawValue as String?,
                              let signal = TakiSignal(notificationName: raw) else { return }
                        Unmanaged<ObserverBox>.fromOpaque(observer).takeUnretainedValue()
                            .continuation.yield(signal)
                    },
                    signal.notificationName as CFString, nil, .deliverImmediately
                )
            }
            continuation.onTermination = { _ in
                CFNotificationCenterRemoveEveryObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(box).toOpaque()
                )
            }
        }
    }

    private final class ObserverBox: Sendable {
        let continuation: AsyncStream<TakiSignal>.Continuation
        init(continuation: AsyncStream<TakiSignal>.Continuation) { self.continuation = continuation }
    }
}
