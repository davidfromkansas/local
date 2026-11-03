import SwiftUI

extension Color {
    static let takiAccent = Color(red: 0.05, green: 0.47, blue: 0.43)
    static let takiRecording = Color(red: 0.92, green: 0.30, blue: 0.26)
}

extension Animation {
    /// Default UI motion: quick, no bounce.
    static let takiSnappy = Animation.snappy(duration: 0.28)
    /// Press feedback: fast, interruptible, a touch of spring on release.
    static let takiPress = Animation.spring(duration: 0.2, bounce: 0.2)
}
