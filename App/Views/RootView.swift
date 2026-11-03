import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.onboarded) private var onboarded = false

    var body: some View {
        TabView {
            Tab("Home", systemImage: "waveform") { HomeView() }
            Tab("History", systemImage: "clock") { HistoryView() }
            Tab("Dictionary", systemImage: "character.book.closed") { DictionaryView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) {
            OnboardingView()
        }
        .overlay {
            if model.showSwipeBack {
                SwipeBackOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.takiSnappy, value: model.showSwipeBack)
    }
}

/// Shown after the keyboard opens the app: the session is live, go back to where you were typing.
struct SwipeBackOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nudge = false

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 20) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward")
                        .offset(x: nudge && !reduceMotion ? -6 : 0)
                    Text("Swipe back to continue")
                }
                .font(.title2.weight(.semibold))
                Text("Taki is listening for your keyboard. Tap ◀︎ in the top-left corner, or swipe right along the bottom edge, to go back to your app.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Stay in Taki") { model.showSwipeBack = false }
                    .buttonStyle(.bordered)
                    .padding(.top, 8)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { nudge = true }
        }
        .onChange(of: model.hotMic.phase) { _, phase in
            if phase == .inactive { model.showSwipeBack = false }
        }
    }
}
