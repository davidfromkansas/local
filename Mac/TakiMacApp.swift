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

        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            Image(systemName: delegate.model.menuSymbol)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MacModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bench = BenchCommand(arguments: CommandLine.arguments) {
            Task {
                await bench.run()
                exit(0)
            }
            return
        }
        model.start()
    }
}
