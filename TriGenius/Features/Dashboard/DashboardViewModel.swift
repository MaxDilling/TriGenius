import Foundation

// MARK: - Dashboard ViewModel
//
// Reads exclusively from the local `TrainingDataStore` (the source-agnostic
// single source of truth) plus the analytics layer — NOT live from HealthKit.

/// The bits of app/athlete state the dashboard needs that don't live in the DB:
/// the active data source, the plan/structure feeding weekly targets, and a
/// factory for the active LLM backend (the AI insight). Lives on the MainActor.
struct DashboardContext {
    let dataSource: DataSource
    let weeklyStructure: WeeklyStructure
    let trainingPlan: TrainingPlan
    let makeBackend: () -> LLMBackend
}

/// One day in the forward-looking Agenda: completed activities (today) and
/// planned workouts (today + upcoming).
struct AgendaDay: Identifiable {
    let date: Date
    let completed: [ActivityRecord]
    let planned: [ScheduledWorkoutRecord]
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

    /// Re-sync from the active source, then recompute everything.
    func refresh(context: DashboardContext) async {
        await DataSyncCoordinator.shared.sync(source: context.dataSource)
        await load(context: context)
    }

    func load(context: DashboardContext) async {
        isLoading = true
        errorMessage = nil

        let store = TrainingDataStore.shared
        let records = store.activities() // newest first
        pmc = PMCEngine.current()
        weeklyBuckets = TrainingVolume.weeklyBuckets(records: records)

        // This week's planned workouts drive the per-discipline targets.
        let cal = Calendar.current
        let weekStart = TrainingVolume.weekStart(of: Date())
        let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let weekScheduled = store.scheduledWorkouts(from: weekStart, to: weekEnd)
        targets = WeeklyTargets.targets(
            scheduled: weekScheduled,
            weeklyStructure: context.weeklyStructure,
            plan: context.trainingPlan
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

    private static func buildAgenda(records: [ActivityRecord], store: TrainingDataStore) -> [AgendaDay] {
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
        let fallback = Self.heuristicInsight(targets: targets, currentWeek: currentWeek)
        let (summary, signature) = Self.insightInputs(pmc: pmc, targets: targets, currentWeek: currentWeek)

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

    private static func heuristicInsight(targets: [SportFamily: WeeklyTarget], currentWeek: TrainingVolume.WeekBucket?) -> String {
        // Discipline furthest below its weekly target (by time).
        let gaps: [(SportFamily, Double)] = SportFamily.triathlon.map { fam in
            let actual = currentWeek?.totals(for: fam).durationMinutes ?? 0
            let target = (targets[fam]?.durationMinutes) ?? 0
            return (fam, target - actual)
        }
        guard let worst = gaps.max(by: { $0.1 < $1.1 }), worst.1 > 15 else {
            return "Nicely balanced week so far — keep it up."
        }
        return "You're still short ~\(durationHM(worst.1)) of \(worst.0.displayName.lowercased()) to hit this week's target."
    }

    /// Build the compact data summary + a launch-stable signature for caching.
    ///
    /// The Form (TSB) line is PRE-CLASSIFIED here (not left to the model to
    /// interpret) so a small on-device model can't misread a normal negative TSB as
    /// "hard training / recover" — see BUGS.md. Trend deltas give it something to
    /// say beyond the raw level.
    private static func insightInputs(
        pmc: PMCResult?,
        targets: [SportFamily: WeeklyTarget],
        currentWeek: TrainingVolume.WeekBucket?
    ) -> (summary: String, signature: Int) {
        var lines: [String] = []
        if let s = pmc?.snapshot {
            let ctlTrend = trendWord(delta: delta7(pmc) { $0.ctl })
            lines.append("Fitness (CTL) \(Int(s.ctl.rounded())) (\(ctlTrend) over 7 days); Fatigue (ATL) \(Int(s.atl.rounded())); Form (TSB) \(Int(s.tsb.rounded())).")
            lines.append("Form interpretation: \(formInterpretation(tsb: s.tsb, ctl: s.ctl))")
            for sig in ProactiveCoach.signals(from: s) {
                lines.append("Flag: \(sig.message)")
            }
        }
        lines.append("This week per discipline (actual vs target — minutes, TSS):")
        for fam in SportFamily.triathlon {
            let a = currentWeek?.totals(for: fam) ?? VolumeTotals()
            let t = targets[fam] ?? WeeklyTarget(durationMinutes: 0, tss: 0)
            lines.append("- \(fam.displayName): \(Int(a.durationMinutes.rounded()))/\(Int(t.durationMinutes.rounded())) min, \(Int(a.tss.rounded()))/\(Int(t.tss.rounded())) TSS")
        }
        let summary = lines.joined(separator: "\n")
        return (summary, stableHash(summary))
    }

    /// Plain-language read of Form (TSB) so the model classifies it correctly.
    /// Negative-while-building is the productive norm, not a recovery flag.
    private static func formInterpretation(tsb: Double, ctl: Double) -> String {
        switch tsb {
        case ..<(-30):
            return "fatigue is HIGH (deep negative) — recovery is genuinely warranted before adding load."
        case ..<(-10):
            return "productive training zone — this negative Form is normal and desirable while building fitness; NOT a recovery flag."
        case ..<5:
            return "neutral / maintenance — balanced load and recovery."
        case ..<15:
            return "fresh — well recovered, good for a key session."
        default:
            return ctl < 20
                ? "very fresh but fitness (CTL) is low — this points to detraining, not race-readiness; consistent volume is the lever."
                : "very fresh / tapered — race-ready."
        }
    }

    /// 7-day change in a PMC metric, or 0 when history is too short.
    private static func delta7(_ pmc: PMCResult?, _ metric: (PMCPoint) -> Double) -> Int {
        guard let now = pmc?.points.last.map(metric),
              let then = pmc?.value(daysAgo: 7, metric) else { return 0 }
        return Int((now - then).rounded())
    }

    private static func trendWord(delta: Int) -> String {
        if delta > 1 { return "rising +\(delta)" }
        if delta < -1 { return "falling \(delta)" }
        return "flat"
    }

    /// Deterministic djb2 hash — `String.hashValue` is per-process randomized,
    /// which would break the cross-launch per-day insight cache.
    private static func stableHash(_ s: String) -> Int {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) ^ UInt64(b) }
        return Int(bitPattern: UInt(truncatingIfNeeded: h))
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
