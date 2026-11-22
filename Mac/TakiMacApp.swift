import AppKit
import Sparkle
import SwiftUI

@main
struct TakiMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Taki", id: "main") {
            MainWindow(model: delegate.model)
        }
        .defaultSize(width: 560, height: 640)
        .defaultLaunchBehavior(delegate.model.needsSetup ? .presented : .suppressed)

        #if DEBUG
        Window("Orb Tuner", id: "orbTuner") {
            OrbTunerWindow(model: delegate.model)
        }
        .defaultSize(width: 860, height: 720)
        #endif

        MenuBarExtra {
            MenuContent(model: delegate.model, updater: delegate.updater)
        } label: {
            Image(systemName: delegate.model.menuSymbol)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MacModel()
    let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let bench = BenchCommand(arguments: CommandLine.arguments) {
            Task {
                await bench.run()
                exit(0)
            }
            return
        }
        #endif
        if InstallLocation.needsMove {
            InstallLocation.askToMove()
            return
        }
        model.start()
        updater.start()
    }
}

/// Sparkle auto-updates from the appcast on GitHub Releases. Off when the build has no feed or key
/// (local/dev builds), so they never offer to replace themselves with a release.
@Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    private(set) var canCheck = false

    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = info["SUFeedURL"] as? String ?? "", key = info["SUPublicEDKey"] as? String ?? ""
        return feed.hasPrefix("https://") && !key.isEmpty
    }

    func start() {
        guard Self.isConfigured else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        canCheck = true
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    // Taki lives in the menu bar, so a scheduled update alert would open behind other apps.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        NSApp.activate()
    }
}

/// Running straight from the downloaded disk image (or a quarantined copy macOS moved to a random
/// folder) breaks updates and the Accessibility permission, so ask people to drag Taki to Applications.
enum InstallLocation {
    static var needsMove: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    static func askToMove() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move Taki to Applications first"
        alert.informativeText = "Drag Taki into the Applications folder in the window that opened, then open it from Applications."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
