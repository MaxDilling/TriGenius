import SwiftUI
import SwiftData

// MARK: - App Root

@main
struct TriGeniusApp: App {
    @StateObject private var memory = CoachMemory()
    @StateObject private var settings = AppSettings()
    @State private var brain: CoachBrain?
    @State private var launchStatus = "Initialisiere…"
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Register the background-refresh handler before launch completes, as
        // BGTaskScheduler requires. No-op on macOS.
        BackgroundCoordinator.shared.register()
    }

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
        .onChange(of: scenePhase) { _, phase in
            // Queue a background refresh when leaving the foreground, so proactive
            // signals can be evaluated while the app is suspended.
            if phase == .background, settings.proactiveNotifications {
                BackgroundCoordinator.shared.schedule()
            }
        }
    }

    private func setupBrain() async {
        let b = CoachBrain(memory: memory, dataSource: settings.dataSource)
        // Live read of Debug Mode — captured once so toggling never resets the chat.
        b.isDebugEnabled = { [weak settings] in settings?.debugMode ?? false }
        applyBackend(to: b)
        // One-time migration: seed the performance-metric time series from any
        // legacy `coach_memory.json` scalars before the first save drops them.
        seedPerformanceMetricsIfNeeded()
        // GOAL.md step 2: sync the latest activities into the local database
        // before revealing the UI, so the coach reads 100% fresh data.
        launchStatus = "Synchronisiere Aktivitäten…"
        await DataSyncCoordinator.shared.sync(source: settings.dataSource)
        brain = b
    }

    /// Migrate performance scalars that used to live in `coach_memory.json`
    /// (FTP, CSS, VO2max, lactate-threshold HR) into the SwiftData time series.
    /// Runs once, gated by a UserDefaults flag; reads the legacy fields parsed by
    /// `CoachMemory.init` before `UserProfile.toDict()` stops emitting them.
    @MainActor
    private func seedPerformanceMetricsIfNeeded() {
        // v2: also migrates weight and HR/power zones (added after v1 shipped).
        // v3: also migrates max HR (was the last performance value still in the profile).
        let key = "trigenius.perfMetricsSeeded.v3"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let metrics = DataSyncCoordinator.metrics(fromProfile: memory.userProfile, date: Date())
        TrainingDataStore.shared.ingestMetrics(metrics)
        UserDefaults.standard.set(true, forKey: key)
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
                DashboardView(
                    dataSource: settings.dataSource,
                    athleteName: memory.userProfile.name,
                    weeklyStructure: memory.weeklyStructure,
                    trainingPlan: memory.trainingPlan,
                    memory: memory,
                    makeBackend: { settings.makeBackend() }
                )
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
                    brain: brain,
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
