import SwiftUI
import SwiftData

// MARK: - App Root

@main
struct TriGeniusApp: App {
    @StateObject private var memory = CoachMemory()
    @StateObject private var settings = AppSettings()
    @State private var router = CoachRouter()
    @State private var brain: CoachBrain?
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
                ProgressView("Initialisiere…")
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
#if os(macOS)
        .commands { CheckForUpdatesCommand() }
#endif
    }

    private func setupBrain() async {
        // The unit-test bundle is injected into this app as its host; skip the
        // launch sync pipeline (network/HealthKit) so tests stay fast and offline.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // Allow notifications to present while the app is in the foreground —
        // without this, reminders fired from the Test Reminders screen are
        // silently suppressed by iOS.
        NotificationCenterService.shared.configure()
        // Mirror the iCloud-KVS ignored-workout blacklist into the local store and
        // keep watching for changes from the athlete's other devices.
        IgnoredWorkouts.startSync()
        // Translate pre-layer workout rows (planned slot, actual date/time,
        // override layer) before anything reads or syncs the store.
        TrainingDataStore.shared.migrateWorkoutLayersIfNeeded()
        // Route a tapped notification's follow-up prompt into the chat (unsent).
        NotificationCenterService.shared.onNotificationTap = { [router] prompt in
            router.openChat(prefill: prompt)
        }
        let b = CoachBrain(memory: memory, readSources: settings.readSources, writeTarget: settings.writeTarget)
        // Live read of Debug Mode — captured once so toggling never resets the chat.
        b.isDebugEnabled = { [weak settings] in settings?.debugMode ?? false }
        applyBackend(to: b)
        // Reveal the UI immediately from the cached SwiftData store — the migrations
        // above are local and instant; the network sync must NOT gate first paint.
        brain = b
        // Sync in the background: its store writes post `trainingDataDidChange`, so the
        // Dashboard/Calendar/etc. refresh in place when fresh data lands. (Trade-off:
        // for the first ~seconds the coach reads last-sync data — acceptable, the store
        // already holds the previous run's history and this self-heals on arrival.)
        let readSources = settings.readSources
        let writeTarget = settings.writeTarget
        Task {
            await DataSyncCoordinator.shared.syncAll(readSources)
            // Push any upcoming plans the active write target hasn't seen yet (e.g. after
            // a target switch), so nothing is lost.
            await DataSyncCoordinator.shared.reconcileWriteTarget(writeTarget)
            // Re-register OS-scheduled reminders — pending requests are cleared on
            // reboot / app update, so reconcile on every launch.
            await ReminderScheduler.shared.reconcile()
        }
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

    /// First-launch medical disclaimer gate (Guideline 1.4.1).
    @AppStorage("medical_disclaimer_accepted") private var disclaimerAccepted = false

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
                CalendarView()
            }
            .tag(CoachRouter.RootTab.calendar)
            .tabItem {
                Label("Calendar", systemImage: "calendar")
            }
        }
        .environment(router)
        // Trace marker: aligns the Instruments timeline with each tab switch, so
        // hangs/hitches right after it attribute to that tab's first build + load.
        .onChange(of: router.selectedTab) { old, new in
            Perf.event("tabSwitch", "\(old)→\(new)")
        }
        .sheet(isPresented: Binding(get: { !disclaimerAccepted }, set: { _ in })) {
            MedicalDisclaimerView { disclaimerAccepted = true }
        }
    }
}
