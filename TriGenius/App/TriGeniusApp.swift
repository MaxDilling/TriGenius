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
        let p = memory.userProfile
        let now = Date()
        var metrics: [IngestedMetric] = []
        if let ftp = p.ftp {
            metrics.append(IngestedMetric(metricKey: "cycling_ftp", value: Double(ftp), unit: "watts", source: "manual", date: now))
        }
        if let css = p.cssPace, let secs = DataSyncCoordinator.paceSeconds(from: css) {
            metrics.append(IngestedMetric(metricKey: "swim_css_pace", value: secs, unit: "sec_per_100m", source: "manual", date: now))
        }
        if let vo2 = p.vo2max {
            metrics.append(IngestedMetric(metricKey: "vo2max_running", value: vo2, unit: "ml_kg_min", source: "manual", date: now))
        }
        if let lthr = p.lactateThrHR {
            metrics.append(IngestedMetric(metricKey: "lactate_threshold_hr", value: Double(lthr), unit: "bpm", source: "manual", date: now))
        }
        if let maxHR = p.maxHR {
            metrics.append(IngestedMetric(metricKey: "max_hr", value: Double(maxHR), unit: "bpm", source: "manual", date: now))
        }
        if let weight = p.weightKg {
            metrics.append(IngestedMetric(metricKey: "weight_kg", value: weight, unit: "kg", source: "manual", date: now))
        }
        metrics += DataSyncCoordinator.zoneMetrics(p.zones["hr_zones"], prefix: "hr_zone", unit: "bpm", source: "manual", date: now)
        metrics += DataSyncCoordinator.zoneMetrics(p.zones["power_zones"], prefix: "power_zone", unit: "watts", source: "manual", date: now)
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
