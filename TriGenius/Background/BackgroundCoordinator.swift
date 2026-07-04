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

        await DataSyncCoordinator.shared.syncAll(AppSettings.storedReadSources())
        // Re-push local plan changes to the provider (incl. re-creating plans the
        // athlete deleted on the provider side — local is the source of truth).
        await DataSyncCoordinator.shared.reconcileWriteTarget(AppSettings.storedWriteTarget())

        // The snapshot doesn't need the forward projection (only the weekly-target
        // check below uses planned workouts), so skip it here.
        let snapshot = PMCEngine.current(forecastDays: 0).snapshot
        var signals = ProactiveCoach.signals(from: snapshot)

        // Weekly-target-at-risk warning (FEATURES.md "TSS / TSB forecast"): compare
        // this week's per-discipline target against the projected close (completed
        // + still-planned). The targets need the athlete's plan/structure; a fresh
        // CoachMemory reads the persisted coach_memory.json on init.
        let memory = CoachMemory()
        let cal = Calendar.current
        let weekStart = TrainingVolume.weekStart(of: Date())
        let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let weekScheduled = TrainingDataStore.shared.scheduledWorkouts(from: weekStart, to: weekEnd)
        let targets = WeeklyTargets.targets(
            scheduled: weekScheduled,
            weeklyStructure: memory.weeklyStructure,
            atpPlan: ATPEngine.current()
        )
        var projection = WeeklyTargets.projection(store: TrainingDataStore.shared)
        signals += ProactiveCoach.weeklyTargetSignals(targets: targets, projection: projection)

        // Apply cross-training credit + the visible-family gate so the background
        // widget refresh matches the foreground dashboard exactly.
        WeeklyTargets.applyCrossTrainingCredit(targets: targets, into: &projection,
                                               factor: AppSettings.storedCreditFactor())
        let visible = WeeklyTargets.visibleFamilies(sportRatio: memory.weeklyStructure.sportRatio)

        // Refresh the Home Screen widget's snapshot from the same numbers, so it
        // stays current even when the app is only woken in the background.
        WeeklyTargetSnapshotWriter.write(targets: targets, projections: projection,
                                         families: visible, weekStart: weekStart)

        await NotificationCenterService.shared.postDailyDigest(signals)

        await deliverDueDynamicReminders()
    }

    // MARK: - Dynamic reminders
    //
    // "Erweiterte Reminder": dynamic reminders compose their body from fresh data,
    // so they can't be a fixed OS calendar trigger — they're delivered from this
    // refresh when due (configured time passed today, not in quiet hours, not
    // already sent today). Static reminders fire directly via the OS (see
    // ReminderScheduler) and don't need the background path.

    /// Post any dynamic reminders that have come due. The store already filters by
    /// time-of-day, weekday and quiet hours; the scheduler guards per-day dedup.
    private func deliverDueDynamicReminders() async {
        for rule in ReminderStore.shared.dueDynamicRules()
        where !ReminderScheduler.shared.dynamicDeliveredToday(rule.id) {
            guard let body = await composeDynamicBody(for: rule.kind) else { continue }
            let posted = await NotificationCenterService.shared.post(
                title: "TriGenius",
                body: body,
                identifier: "trigenius.reminder.dyn.\(rule.id)",
                followUpPrompt: rule.kind.followUpPrompt
            )
            if posted { ReminderScheduler.shared.markDynamicDelivered(rule.id) }
        }
    }

    /// Developer/testing: compose and immediately deliver a dynamic reminder,
    /// bypassing the per-day dedup. Returns the delivered body, or nil when there
    /// was nothing worth saying for that kind right now.
    @discardableResult
    func sendDynamicReminderTest(_ kind: ReminderKind) async -> String? {
        guard let body = await composeDynamicBody(for: kind) else { return nil }
        await NotificationCenterService.shared.post(
            title: "TriGenius",
            body: body,
            identifier: "trigenius.reminder.test.\(UUID().uuidString)",
            followUpPrompt: kind.followUpPrompt
        )
        return body
    }

    /// Build the notification body for a dynamic reminder from current data.
    /// Returns nil to skip delivery (nothing worth saying).
    func composeDynamicBody(for kind: ReminderKind) async -> String? {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date())
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let todays = TrainingDataStore.shared.scheduledWorkouts(from: dayStart, to: dayEnd)

        switch kind {
        case .todaysWorkout:
            guard !todays.isEmpty else { return "No workout planned today — enjoy the rest day." }
            let parts = todays.map { w -> String in
                let family = SportFamily(sportKey: w.sport).displayName
                let mins = Int(w.plannedDurationMinutes.rounded())
                var s = family
                if mins > 0 { s += " · \(mins)min" }
                if let start = w.startMinute { s += " @ \(Self.clockString(start))" }
                return s
            }
            return "Today's training: " + parts.joined(separator: ", ")

        case .sleepAdvice:
            let plannedTSS = PMCEngine.plannedTSSByDay(todays).values.reduce(0, +)
            let sleep = await recentSleepHours()
            let demanding = plannedTSS >= 80
            if let sleep, sleep < 6.5 {
                return demanding
                    ? "You slept ~\(String(format: "%.1f", sleep))h and have a demanding day planned (TSS ~\(Int(plannedTSS.rounded()))). Consider easing the intensity or shifting the hard session."
                    : "You slept ~\(String(format: "%.1f", sleep))h — keep today easy and prioritise recovery."
            }
            if demanding {
                return "Demanding session planned today (TSS ~\(Int(plannedTSS.rounded()))). Make sure you're well recovered before going hard."
            }
            return nil

        default:
            return nil
        }
    }

    /// Best-effort most-recent night's sleep duration from the local wellness
    /// time series (populated by the data-source sync). Returns the latest stored
    /// night within the last two days, or nil for load-only advice when none.
    private func recentSleepHours() async -> Double? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -2, to: Calendar.current.startOfDay(for: Date()))!
        let recent = TrainingDataStore.shared.metricHistory("sleep_duration_h").filter { $0.date >= cutoff }
        guard let last = recent.last, last.value > 0 else { return nil }
        return last.value
    }

    private static func clockString(_ minutesAfterMidnight: Int) -> String {
        String(format: "%02d:%02d", minutesAfterMidnight / 60, minutesAfterMidnight % 60)
    }
}
