import SwiftUI
import SwiftData

// MARK: - App Root

@main
struct TriGeniusApp: App {
    @StateObject private var memory = CoachMemory()
    @StateObject private var settings = AppSettings()
    @State private var brain: CoachBrain?
    @State private var launchStatus = "Initialisiere…"

    var body: some Scene {
        WindowGroup {
            if let brain {
                RootTabView(brain: brain, memory: memory, settings: settings) {
                    applyBackend(to: brain)
                }
            } else {
                ProgressView(launchStatus)
                    .task { await setupBrain() }
            }
        }
        .modelContainer(TrainingDataStore.shared.container)
    }

    private func setupBrain() async {
        let b = CoachBrain(memory: memory, dataSource: settings.dataSource)
        // Live read of Debug Mode — captured once so toggling never resets the chat.
        b.isDebugEnabled = { [weak settings] in settings?.debugMode ?? false }
        applyBackend(to: b)
        // GOAL.md step 2: sync the latest activities into the local database
        // before revealing the UI, so the coach reads 100% fresh data.
        launchStatus = "Synchronisiere Aktivitäten…"
        await DataSyncCoordinator.shared.sync(source: settings.dataSource)
        brain = b
    }

    private func applyBackend(to brain: CoachBrain) {
        brain.setDataSource(settings.dataSource)
        brain.setBackend(settings.makeBackend())
    }
}

// MARK: - Root Tab View

struct RootTabView: View {
    let brain: CoachBrain
    @ObservedObject var memory: CoachMemory
    @ObservedObject var settings: AppSettings
    let onBackendChanged: () -> Void

    var body: some View {
        TabView {
            NavigationStack {
                DashboardView(dataSource: settings.dataSource)
            }
            .tabItem {
                Label("Dashboard", systemImage: "chart.xyaxis.line")
            }

            NavigationStack {
                CoachChatView(brain: brain)
            }
            .tabItem {
                Label("Coach", systemImage: "bubble.left.and.bubble.right.fill")
            }
            NavigationStack {
                SettingsView(
                    settings: settings,
                    memory: memory,
                    onBackendChanged: onBackendChanged
                )
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
        }
    }
}
