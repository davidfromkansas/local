import Foundation
import Testing
@testable import Taki
import TakiEngine

/// App-level smoke tests (the pure logic lives in TakiCoreTests).
@MainActor
struct AppSmokeTests {
    @Test func settingsDefaultsAreRegistered() {
        let model = AppModel()
        #expect(model.modelChoice == .parakeetUnified)
        #expect(UserDefaults.standard.double(forKey: SettingsKey.timeout) == 0)
        #expect(model.hotMic.phase == .inactive)
    }
}
