import Foundation

// MARK: - Dashboard ViewModel
//
// Reads exclusively from the local `TrainingDataStore` (the source-agnostic
// single source of truth) plus the analytics layer — NOT live from HealthKit.

/// The bits of app/athlete state the dashboard needs that don't live in the DB:
/// the active data source, the plan/structure feeding weekly targets, and a
/// factory for the active LLM backend (the AI insight). Lives on the MainActor.
struct DashboardContext {
    let readSources: Set<DataSource>
    let weeklyStructure: WeeklyStructure
    let makeBackend: () -> LLMBackend
    /// Whether the athlete opted into the AI insight card (Settings → Dashboard).
    let aiInsightEnabled: Bool
}

/// One day in the forward-looking Agenda: completed activities (today) and
/// planned workouts (today + upcoming).
struct AgendaDay: Identifiable {
    let date: Date
    let completed: [WorkoutRecord]
    let planned: [WorkoutRecord]
    var id: Date { date }
}

@MainActor
@Observable
final class DashboardViewModel {
    var pmc: PMCResult?
    var weeklyBuckets: [TrainingVolume.WeekBucket] = []
    var targets: [SportFamily: WeeklyTarget] = [:]
    /// Per-discipline expected week close (completed + still-planned) — the faded
    /// projection arc on the weekly rings.
    var projections: [SportFamily: WeeklyProjection] = [:]
    var agendaDays: [AgendaDay] = []
    var insight: String?
    var isLoading = false
    var errorMessage: String?

    private var hasLoaded = false
    private var insightTask: Task<Void, Never>?

    /// The current (most recent) week bucket, for the "this week" summary.
    var currentWeek: TrainingVolume.WeekBucket? { weeklyBuckets.last }

    func target(for family: SportFamily) -> WeeklyTarget {
        targets[family] ?? WeeklyTarget(durationMinutes: 0, tss: 0)
    }

    func projection(for family: SportFamily) -> WeeklyProjection {
        projections[family] ?? WeeklyProjection()
    }

    func loadInitialIfNeeded(context: DashboardContext) async {
        guard !hasLoaded else { return }
        await load(context: context)
    }

    /// Re-sync from all enabled sources, then recompute everything.
    func refresh(context: DashboardContext) async {
        await DataSyncCoordinator.shared.syncAll(context.readSources)
        // Push local plan changes down to the provider — including re-creating any
        // TriGenius plan the athlete deleted on the provider side (local is source of
        // truth). syncAll just cleared the dead refs; this re-pushes them.
        await DataSyncCoordinator.shared.reconcileWriteTarget(AppSettings.storedWriteTarget())
        await load(context: context)
    }

    func load(context: DashboardContext) async {
        let perf = Perf.begin("DashboardVM.load"); defer { Perf.end(perf) }
        isLoading = true
        errorMessage = nil

        let store = TrainingDataStore.shared
        let records = store.activities() // newest first
        pmc = PMCEngine.current()
        weeklyBuckets = TrainingVolume.weeklyBuckets(records: records)
        let atpPlan = ATPEngine.current()

        // This week's planned workouts drive the per-discipline targets.
        let cal = Calendar.current
        let weekStart = TrainingVolume.weekStart(of: Date())
        let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let weekScheduled = store.scheduledWorkouts(from: weekStart, to: weekEnd)
        targets = WeeklyTargets.targets(
            scheduled: weekScheduled,
            weeklyStructure: context.weeklyStructure,
            atpPlan: atpPlan
        )
        projections = WeeklyTargets.projection(store: store)

        // Keep the Home Screen widget's snapshot in sync with what the dashboard
        // is showing.
        WeeklyTargetSnapshotWriter.write(targets: targets, projections: projections, weekStart: weekStart)

        agendaDays = Self.buildAgenda(records: records, store: store)

        hasLoaded = true
        isLoading = false

        refreshInsight(context: context)
    }

    // MARK: - Agenda

    /// How many days ahead the Agenda surfaces planned workouts.
    private static let agendaUpcomingDays = 7

    private static func buildAgenda(records: [WorkoutRecord], store: TrainingDataStore) -> [AgendaDay] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: agendaUpcomingDays, to: today) ?? today
        // `openScheduledWorkouts` already drops plans whose completion has landed,
        // so a done session never shows twice (pending plan + completed ✓).
        let planned = store.openScheduledWorkouts(from: today, to: end)

        var days: [AgendaDay] = []
        for offset in 0...agendaUpcomingDays {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            // Completed activities only matter for today (past days roll off the agenda).
            let completed = offset == 0
                ? records.filter { cal.isDate($0.date, inSameDayAs: day) }.sorted { $0.date < $1.date }
                : []
            let dayPlanned = planned.filter { cal.isDate($0.date, inSameDayAs: day) }
            if completed.isEmpty && dayPlanned.isEmpty { continue }
            days.append(AgendaDay(date: day, completed: completed, planned: dayPlanned))
        }
        return days
    }

    // MARK: - AI insight

    private func refreshInsight(context: DashboardContext) {
        guard context.aiInsightEnabled else {
            insightTask?.cancel()
            insight = nil
            return
        }
        let fallback = Self.heuristicInsight(targets: targets, currentWeek: currentWeek)
        let (summary, signature) = DashboardInsightInput.build(
            store: TrainingDataStore.shared,
            pmc: pmc,
            weeklyBuckets: weeklyBuckets,
            targets: targets,
            projections: projections,
            weeklyStructure: context.weeklyStructure,
            atpPlan: ATPEngine.current()
        )

        if let cached = DashboardInsight.cached(signature: signature) {
            insight = cached
            return
        }
        // Show the heuristic immediately, then upgrade to the AI line when ready.
        insight = fallback
        insightTask?.cancel()
        insightTask = Task { [weak self] in
            let text = await DashboardInsight.generate(
                summary: summary,
                signature: signature,
                fallback: fallback,
                makeBackend: context.makeBackend
            )
            guard !Task.isCancelled else { return }
            self?.insight = text
        }
    }

    /// Discipline furthest below its weekly target (by time) and its shortfall in
    /// minutes — the shared basis for the heuristic insight line and the tap-through
    /// follow-up prompt. nil when no discipline is meaningfully behind.
    private static func worstGap(targets: [SportFamily: WeeklyTarget], currentWeek: TrainingVolume.WeekBucket?) -> (family: SportFamily, gapMinutes: Double)? {
        let gaps: [(SportFamily, Double)] = SportFamily.triathlon.map { fam in
            let actual = currentWeek?.totals(for: fam).durationMinutes ?? 0
            let target = (targets[fam]?.durationMinutes) ?? 0
            return (fam, target - actual)
        }
        guard let worst = gaps.max(by: { $0.1 < $1.1 }), worst.1 > 15 else { return nil }
        return (worst.0, worst.1)
    }

    private static func heuristicInsight(targets: [SportFamily: WeeklyTarget], currentWeek: TrainingVolume.WeekBucket?) -> String {
        guard let worst = worstGap(targets: targets, currentWeek: currentWeek) else {
            return "Nicely balanced week so far — keep it up."
        }
        return "You're still short ~\(durationHM(worst.gapMinutes)) of \(worst.family.displayName.lowercased()) to hit this week's target."
    }

    /// Deterministic chat prompt to pre-fill (unsent) when the athlete taps the AI
    /// insight card — mirrors the same worst-gap read the card itself is built on.
    var insightFollowUpPrompt: String {
        if let worst = Self.worstGap(targets: targets, currentWeek: currentWeek) {
            return "Plan a \(worst.family.displayName.lowercased()) workout for me this week."
        }
        return "Give me a quick review of my training week."
    }

    /// The complete prompt sent to generate the dashboard one-liner — the static
    /// system prompt plus the live, pre-classified data summary that goes out as
    /// the user message — assembled from the current local store + plan. Pure and
    /// side-effect-free (no widget write, no backend call / caching), so the Debug
    /// Mode viewer in Settings can show exactly what the model would receive.
    static func debugInsightPrompt(context: DashboardContext) -> String {
        let store = TrainingDataStore.shared
        let pmc = PMCEngine.current()
        let weeklyBuckets = TrainingVolume.weeklyBuckets(records: store.activities())
        let atpPlan = ATPEngine.current()

        let cal = Calendar.current
        let weekStart = TrainingVolume.weekStart(of: Date())
        let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let targets = WeeklyTargets.targets(
            scheduled: store.scheduledWorkouts(from: weekStart, to: weekEnd),
            weeklyStructure: context.weeklyStructure,
            atpPlan: atpPlan
        )
        let projections = WeeklyTargets.projection(store: store)

        let (summary, _) = DashboardInsightInput.build(
            store: store,
            pmc: pmc,
            weeklyBuckets: weeklyBuckets,
            targets: targets,
            projections: projections,
            weeklyStructure: context.weeklyStructure,
            atpPlan: atpPlan
        )
        return """
        ===== SYSTEM PROMPT =====

        \(DashboardInsight.systemPrompt)

        ===== USER MESSAGE (live data) =====

        \(summary)
        """
    }

    // MARK: PMC deltas (vs. 7 days ago) for the stat cards.

    var ctlDelta: Int { delta { $0.ctl } }
    var atlDelta: Int { delta { $0.atl } }
    var tsbDelta: Int { delta { $0.tsb } }

    private func delta(_ metric: (PMCPoint) -> Double) -> Int {
        guard let now = pmc?.points.last.map(metric),
              let then = pmc?.value(daysAgo: 7, metric) else { return 0 }
        return Int((now - then).rounded())
    }
}
