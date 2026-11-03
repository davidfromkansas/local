import SwiftData
import SwiftUI

@main
struct TakiApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .modelContainer(model.container)
                .tint(.takiAccent)
                .onOpenURL { url in
                    // taki://start — sent by the keyboard when no session is running.
                    guard url.scheme == "taki", url.host() == "start" else { return }
                    model.startSessionFromKeyboard()
                }
                .task { await model.loadModelsIfDownloaded() }
        }
    }
}
