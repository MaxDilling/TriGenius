import Foundation
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

// MARK: - Background Coordinator
//
// Schedules a periodic background refresh that re-syncs the latest training
// data, recomputes the PMC, and — when the athlete opted into proactive
// notifications — surfaces the highest-severity ProactiveCoach signal as a local
// notification. This is the "second sink" the ProactiveCoach was split for: the
// SAME trigger evaluation feeds both the system-prompt section (in-chat) and
// these notifications (background).
//
// FEATURES.md "Background execution + push notifications". BGTaskScheduler is
// iOS-only; on macOS the methods are no-ops so call sites stay platform-agnostic.

@MainActor
final class BackgroundCoordinator {
    static let shared = BackgroundCoordinator()
    private init() {}

    /// Must match the `BGTaskSchedulerPermittedIdentifiers` Info.plist entry.
    static let refreshTaskID = "com.trigenius.refresh"

    /// Minimum spacing between background refreshes (~6h). The system decides the
    /// actual cadence based on usage; this is a floor, not a guarantee.
    private let minInterval: TimeInterval = 6 * 60 * 60

    // MARK: - Registration / scheduling

    /// Register the background task handler. Call once, early in app launch
    /// (before `application(_:didFinishLaunchingWithOptions:)` returns).
    func register() {
        #if os(iOS)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskID,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else { return }
            self?.handle(task)
        }
        #endif
    }

    /// Request a future background refresh. Safe to call repeatedly. No-op when
    /// the identifier isn't permitted (misconfigured plist) — it just won't run.
    func schedule() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Typically BGTaskSchedulerErrorDomain — not permitted, simulator, or
            // already-pending. Non-fatal; the feature simply stays dormant.
            print("⏱️ [TriGenius] background refresh not scheduled: \(error.localizedDescription)")
        }
        #endif
    }

    /// Stop future background refreshes (athlete turned notifications off).
    func cancel() {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskID)
        #endif
    }

    // MARK: - Task handling

    #if os(iOS)
    private func handle(_ task: BGAppRefreshTask) {
        // Always chain the next refresh so the cadence keeps going.
        schedule()

        let work = Task { @MainActor in
            await self.runProactiveCheck()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
    #endif

    // MARK: - Shared proactive check

    /// Sync the active source, recompute the PMC, and post a proactive
    /// notification if warranted. Reused by the background task and (optionally)
    /// a foreground refresh. Gated on the athlete's notification opt-in.
    func runProactiveCheck() async {
        guard UserDefaults.standard.bool(forKey: AppSettings.proactiveNotificationsKey) else { return }

        let source = DataSource(rawValue: UserDefaults.standard.string(forKey: "data_source") ?? "")
            ?? .appleHealth
        _ = await DataSyncCoordinator.shared.sync(source: source)

        let snapshot = PMCEngine.current().snapshot
        let signals = ProactiveCoach.signals(from: snapshot)
        await NotificationCenterService.shared.postDailyDigest(signals)
    }
}
