import SwiftUI
import SwiftData

// MARK: - App Root

@main
struct TriGeniusApp: App {
    @StateObject private var memory = CoachMemory()
    @StateObject private var settings = AppSettings()
    @State private var router = CoachRouter()
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
                RootTabView(brain: brain, memory: memory, settings: settings, router: router) {
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
        // The unit-test bundle is injected into this app as its host; skip the
        // launch sync pipeline (network/HealthKit) so tests stay fast and offline.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // Allow notifications to present while the app is in the foreground —
        // without this, reminders fired from the Test Reminders screen are
        // silently suppressed by iOS.
        NotificationCenterService.shared.configure()
        // Route a tapped notification's follow-up prompt into the chat (unsent).
        NotificationCenterService.shared.onNotificationTap = { [router] prompt in
            router.openChat(prefill: prompt)
        }
        let b = CoachBrain(memory: memory, readSources: settings.readSources, writeTarget: settings.writeTarget)
        // Live read of Debug Mode — captured once so toggling never resets the chat.
        b.isDebugEnabled = { [weak settings] in settings?.debugMode ?? false }
        applyBackend(to: b)
        // One-time migration: import any legacy `coach_memory.json` into the SwiftData
        // coach-memory rows. Runs BEFORE the perf seed so the legacy profile's FTP/CSS
        // scalars are still on `memory.userProfile` in memory for it to read.
        migrateCoachMemoryIfNeeded()
        // One-time migration: seed the performance-metric time series from any
        // legacy `coach_memory.json` scalars before the first save drops them.
        seedPerformanceMetricsIfNeeded()
        // GOAL.md step 2: sync the latest activities into the local database
        // before revealing the UI, so the coach reads 100% fresh data.
        launchStatus = "Synchronisiere Aktivitäten…"
        await DataSyncCoordinator.shared.syncAll(settings.readSources)
        // Push any upcoming plans the active write target hasn't seen yet (e.g. after
        // a target switch), so nothing is lost.
        await DataSyncCoordinator.shared.reconcileWriteTarget(settings.writeTarget)
        // Re-register OS-scheduled reminders — pending requests are cleared on
        // reboot / app update, so reconcile on every launch.
        await ReminderScheduler.shared.reconcile()
        brain = b
    }

    /// One-time migration: import any pre-existing `coach_memory.json` into the
    /// SwiftData coach-memory rows (now the source of truth, so it rides CloudKit).
    /// Gated by a UserDefaults flag; a no-op when rows already exist or no legacy
    /// file is present. The import repopulates `memory` in place — including the
    /// legacy FTP/CSS scalars the perf seed then reads.
    @MainActor
    private func migrateCoachMemoryIfNeeded() {
        let key = "trigenius.coachMemoryMigrated.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        defer { UserDefaults.standard.set(true, forKey: key) }
        guard !TrainingDataStore.shared.hasCoachMemory,
              let url = CoachMemory.legacyFileURL,
              let data = try? Data(contentsOf: url) else { return }
        try? memory.importJSON(data)
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
        brain.setSources(read: settings.readSources, write: settings.writeTarget)
        brain.setBackend(settings.makeBackend())
        // Re-push upcoming plans to the (possibly newly chosen) write target.
        Task { await DataSyncCoordinator.shared.reconcileWriteTarget(settings.writeTarget) }
    }
}

// MARK: - Root Tab View

struct RootTabView: View {
    let brain: CoachBrain
    @ObservedObject var memory: CoachMemory
    @ObservedObject var settings: AppSettings
    @Bindable var router: CoachRouter
    let onBackendChanged: () -> Void

    var body: some View {
        TabView(selection: $router.selectedTab) {
            NavigationStack {
                DashboardView(
                    readSources: settings.readSources,
                    athleteName: memory.userProfile.name,
                    weeklyStructure: memory.weeklyStructure,
                    memory: memory,
                    makeBackend: { settings.makeBackend() },
                    brain: brain,
                    settings: settings,
                    onBackendChanged: onBackendChanged
                )
            }
            .tag(CoachRouter.RootTab.dashboard)
            .tabItem {
                Label("Dashboard", systemImage: "chart.xyaxis.line")
            }

            NavigationStack {
                ATPTabView()
            }
            .tag(CoachRouter.RootTab.plan)
            .tabItem {
                Label("Plan", systemImage: "chart.bar.xaxis")
            }

            NavigationStack {
                CoachChatView(brain: brain)
            }
            .tag(CoachRouter.RootTab.coach)
            .tabItem {
                Label("Coach", systemImage: "bubble.left.and.bubble.right.fill")
            }

            NavigationStack {
                CalendarView(writeTarget: settings.writeTarget)
            }
            .tag(CoachRouter.RootTab.calendar)
            .tabItem {
                Label("Calendar", systemImage: "calendar")
            }
        }
        .environment(router)
    }
}
