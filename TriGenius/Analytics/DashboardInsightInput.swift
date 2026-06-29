import Foundation

// MARK: - Dashboard Insight Input (pre-classification)
//
// Builds the PRE-CLASSIFIED live-data block the dashboard one-liner model
// receives, plus a launch-stable cache signature. Everything that needs a
// decision — week stage, per-discipline pace, the gap left after the plan,
// last week's verdict, trends — is computed HERE in Swift and emitted as a
// ready-made label, because the model behind the insight is a small (~7B)
// on-device model that must not do arithmetic or temporal reasoning itself.
//
// Pure and side-effect-free (no backend call, no caching, no widget write), so
// both `DashboardViewModel.refreshInsight` and the Settings Debug viewer feed
// the model the exact same string.

@MainActor
enum DashboardInsightInput {

    // MARK: Classification thresholds

    /// Below this fraction of the week's total target completed, the week reads as
    /// freshly begun ("start") — targets reset every Monday, so an empty week is
    /// never "behind". Above `lateProgress` it reads as "late" (header flavour only;
    /// the prompt only branches on start vs. mid/late).
    private static let startProgress = 0.25
    private static let lateProgress = 0.75
    /// A discipline is "behind" only when meaningfully under where it should be by
    /// today, so a small lag against the pro-rated expectation doesn't read as behind.
    private static let paceTolerance = 0.80
    /// TSS below which a residual gap rounds to "none" (noise, not a real shortfall).
    private static let gapEpsilon = 5.0
    /// VO2max trend lookback.
    private static let vo2TrendDays = 30

    enum WeekStage: String { case start, mid, late }

    // MARK: Build

    /// Assemble the live-data block + a deterministic signature for the per-day cache.
    static func build(
        store: TrainingDataStore,
        pmc: PMCResult?,
        weeklyBuckets: [TrainingVolume.WeekBucket],
        targets: [SportFamily: WeeklyTarget],
        projections: [SportFamily: WeeklyProjection],
        weeklyStructure: WeeklyStructure,
        atpPlan: ATPPlan?,
        today: Date = Date()
    ) -> (summary: String, signature: Int) {
        let cal = Calendar.current
        let currentWeek = weeklyBuckets.last
        let lastWeek = weeklyBuckets.dropLast().last

        let weekFraction = fractionOfWeekElapsed(today: today)
        let stage = weekStage(currentWeek: currentWeek, targets: targets)

        var lines: [String] = []
        lines.append(headerLine(atpPlan: atpPlan, stage: stage, today: today))
        if let race = goalRaceLine(atpPlan: atpPlan, today: today) { lines.append(race) }
        lines.append(contentsOf: fitnessLines(pmc: pmc))
        if let vo2 = vo2maxLine(store: store, today: today) { lines.append(vo2) }

        lines.append("")
        lines.append("LAST WEEK (completed) — done vs target:")
        let lwTargets = lastWeekTargets(store: store, weeklyStructure: weeklyStructure, atpPlan: atpPlan, today: today)
        lines.append(contentsOf: lastWeekLines(lastWeek: lastWeek, targets: lwTargets))

        lines.append("")
        lines.append("THIS WEEK — pace vs where you should be by today, and what's planned:")
        lines.append(contentsOf: thisWeekLines(
            store: store, currentWeek: currentWeek, targets: targets, projections: projections,
            stage: stage, weekFraction: weekFraction, today: today, calendar: cal
        ))

        let summary = lines.joined(separator: "\n")
        return (summary, stableHash(summary))
    }

    // MARK: Header & race

    /// The ATP week containing `today`, if the plan covers it.
    private static func currentATPWeek(_ atpPlan: ATPPlan?, today: Date) -> ATPWeekPlan? {
        guard let atpPlan else { return nil }
        let cal = Calendar.current
        let day = cal.startOfDay(for: today)
        return atpPlan.weeks.first { wk in
            let end = cal.date(byAdding: .day, value: 6, to: wk.weekStart) ?? wk.weekStart
            return day >= wk.weekStart && day <= end
        }
    }

    private static func headerLine(atpPlan: ATPPlan?, stage: WeekStage, today: Date) -> String {
        var parts = ["Date: \(DateFormatter.insightHeader.string(from: today))"]
        if let wk = currentATPWeek(atpPlan, today: today) {
            parts.append("\(wk.period.label), week \(wk.periodWeekIndex)")
        }
        parts.append("week_stage = \(stage.rawValue)")
        return parts.joined(separator: " · ")
    }

    /// Goal race as its own field so the prompt degrades gracefully — the next
    /// upcoming A/B event from the ATP; omitted when none is scheduled.
    private static func goalRaceLine(atpPlan: ATPPlan?, today: Date) -> String? {
        guard let atpPlan else { return nil }
        let cal = Calendar.current
        let day = cal.startOfDay(for: today)
        guard let next = atpPlan.events
            .filter({ $0.priority != .c && $0.date >= day })
            .min(by: { $0.date < $1.date }) else { return nil }
        let days = cal.dateComponents([.day], from: day, to: cal.startOfDay(for: next.date)).day ?? 0
        let when = days == 0 ? "today" : "in \(days) day\(days == 1 ? "" : "s")"
        return "Goal race: \(next.name) · \(when)"
    }

    // MARK: Fitness (PMC) — pre-classified

    private static func fitnessLines(pmc: PMCResult?) -> [String] {
        guard let s = pmc?.snapshot else { return [] }
        let ctlDelta = delta(pmc, days: 7) { $0.ctl }
        let trend = trendWord(ctlDelta)
        var out = [
            "Fitness (CTL) \(Int(s.ctl.rounded())), \(signed(ctlDelta))/7d (\(trend)); "
            + "Fatigue (ATL) \(Int(s.atl.rounded())); Form (TSB) \(Int(s.tsb.rounded()))"
        ]
        let high = s.tsb <= -30
        out.append("  → \(formZone(tsb: s.tsb, ctl: s.ctl)); fatigue_flag = \(high ? "high" : "normal")")
        return out
    }

    /// Short, pre-classified read of Form (TSB). Negative-while-building is the
    /// productive norm, never a recovery flag unless fatigue is genuinely high.
    private static func formZone(tsb: Double, ctl: Double) -> String {
        switch tsb {
        case ..<(-30): return "deep fatigue zone — recovery genuinely warranted"
        case ..<(-10): return "productive zone — normal build fatigue, not a recovery flag"
        case ..<5:     return "neutral / maintenance zone"
        case ..<15:    return "fresh zone"
        default:       return ctl < 20 ? "very fresh but low fitness — points to detraining" : "very fresh / tapered — race-ready"
        }
    }

    // MARK: VO2max + trend

    private static func vo2maxLine(store: TrainingDataStore, today: Date) -> String? {
        let history = !store.metricHistory("vo2max_running").isEmpty
            ? store.metricHistory("vo2max_running")
            : store.metricHistory("vo2max_cycling")
        guard let latest = history.last else { return nil }
        let value = Int(latest.value.rounded())
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -vo2TrendDays, to: latest.date),
              let past = history.last(where: { $0.date <= cutoff }) else {
            return "VO2max \(value)"
        }
        let d = Int((latest.value - past.value).rounded())
        return "VO2max \(value), \(signed(d))/\(vo2TrendDays)d"
    }

    // MARK: Last week (completed)

    /// Last week's per-discipline targets, computed against last week's own ATP week
    /// and its own scheduled workouts (not today's) so the verdict is honest.
    private static func lastWeekTargets(
        store: TrainingDataStore, weeklyStructure: WeeklyStructure, atpPlan: ATPPlan?, today: Date
    ) -> [SportFamily: WeeklyTarget] {
        let cal = Calendar.current
        let lwAnchor = cal.date(byAdding: .day, value: -7, to: today) ?? today
        let lwStart = TrainingVolume.weekStart(of: lwAnchor)
        let lwEnd = cal.date(byAdding: .day, value: 6, to: lwStart) ?? lwStart
        return WeeklyTargets.targets(
            scheduled: store.scheduledWorkouts(from: lwStart, to: lwEnd),
            weeklyStructure: weeklyStructure, atpPlan: atpPlan, referenceDate: lwStart
        )
    }

    private static func lastWeekLines(
        lastWeek: TrainingVolume.WeekBucket?, targets: [SportFamily: WeeklyTarget]
    ) -> [String] {
        var metCount = 0
        var targetedCount = 0
        var rows: [String] = []
        for fam in SportFamily.triathlon {
            let actual = lastWeek?.totals(for: fam).tss ?? 0
            let target = targets[fam]?.tss ?? 0
            let label: String
            if target <= 0 {
                label = "no target"
            } else {
                targetedCount += 1
                if actual >= target * 1.1 { label = "over target" }
                else if actual >= target * 0.9 { label = "on target"; metCount += 1 }
                else { label = "under target" }
            }
            rows.append("- \(fam.displayName): \(Int(actual.rounded()))/\(Int(target.rounded())) TSS · \(label)")
        }
        rows.append("→ overall: \(lastWeekVerdict(met: metCount, targeted: targetedCount))")
        return rows
    }

    private static func lastWeekVerdict(met: Int, targeted: Int) -> String {
        guard targeted > 0 else { return "no targets set" }
        if met == targeted { return "strong week, all targets met" }
        if met >= targeted - 1 { return "solid week, mostly on target" }
        return "light week, under target"
    }

    // MARK: This week (pace + plan)

    private static func thisWeekLines(
        store: TrainingDataStore,
        currentWeek: TrainingVolume.WeekBucket?,
        targets: [SportFamily: WeeklyTarget],
        projections: [SportFamily: WeeklyProjection],
        stage: WeekStage,
        weekFraction: Double,
        today: Date,
        calendar cal: Calendar
    ) -> [String] {
        // Still-to-do planned sessions this week (today onward), grouped by family.
        let weekStart = TrainingVolume.weekStart(of: today)
        let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let todayStart = cal.startOfDay(for: today)
        var planned: [SportFamily: [WorkoutRecord]] = [:]
        for w in store.openScheduledWorkouts(from: weekStart, to: weekEnd) where cal.startOfDay(for: w.date) >= todayStart {
            planned[SportFamily(sportKey: w.sport), default: []].append(w)
        }

        var rows: [String] = []
        for fam in SportFamily.triathlon {
            let actual = currentWeek?.totals(for: fam).tss ?? 0
            let target = targets[fam]?.tss ?? 0
            let rawPace = paceLabel(actual: actual, target: target, stage: stage, weekFraction: weekFraction)
            let gap = gapAfterPlan(target: target, projection: projections[fam])
            // A session scheduled for later in the week reads "behind" against the
            // pro-rated pace every day until it's done. If the remaining plan already
            // covers the target the discipline isn't behind — it's on schedule with
            // work still to come — so don't hand the model a "behind" it has to caveat.
            let pace = (rawPace == "behind" && gap == "none")
                ? "on schedule (planned sessions still to come)"
                : rawPace
            let plannedDesc = plannedSessionsDescription(planned[fam] ?? [])
            rows.append("- \(fam.displayName): \(Int(actual.rounded()))/\(Int(target.rounded())) TSS · "
                + "pace = \(pace) · gap_after_plan = \(gap) · planned: \(plannedDesc)")
        }
        return rows
    }

    private static func paceLabel(actual: Double, target: Double, stage: WeekStage, weekFraction: Double) -> String {
        if stage == .start { return "week just started" }
        guard target > 0 else { return "on track" }
        let expected = target * weekFraction
        return actual >= expected * paceTolerance ? "on track" : "behind"
    }

    /// `none` when the remaining planned sessions (the projected week-close) already
    /// meet the target, else the residual TSS still uncovered.
    private static func gapAfterPlan(target: Double, projection: WeeklyProjection?) -> String {
        guard target > 0 else { return "none" }
        let projected = projection?.projectedTSS ?? 0
        let residual = target - projected
        return residual <= gapEpsilon ? "none" : "\(Int(residual.rounded())) TSS"
    }

    /// "N sessions (\"Name\" 37 TSS, …)" — capped so the block stays compact.
    private static func plannedSessionsDescription(_ workouts: [WorkoutRecord]) -> String {
        guard !workouts.isEmpty else { return "none scheduled" }
        let sorted = workouts.sorted { $0.date < $1.date }
        let shown = sorted.prefix(4).map { w -> String in
            let tss = w.targetTSS ?? WeeklyTargets.estimatedTSS(
                family: SportFamily(sportKey: w.sport), minutes: w.targetDurationMinutes)
            return "\"\(w.name)\" \(Int(tss.rounded())) TSS"
        }
        let suffix = sorted.count > 4 ? ", …" : ""
        return "\(sorted.count) session\(sorted.count == 1 ? "" : "s") (\(shown.joined(separator: ", "))\(suffix))"
    }

    // MARK: Week stage

    /// Driven by cumulative completed vs. planned weekly volume (total TSS across
    /// the three disciplines), NOT by weekday — a fresh Monday reads as "start".
    private static func weekStage(
        currentWeek: TrainingVolume.WeekBucket?, targets: [SportFamily: WeeklyTarget]
    ) -> WeekStage {
        let done = SportFamily.triathlon.reduce(0.0) { $0 + (currentWeek?.totals(for: $1).tss ?? 0) }
        let target = SportFamily.triathlon.reduce(0.0) { $0 + (targets[$1]?.tss ?? 0) }
        guard target > 0 else { return .start }
        let progress = done / target
        if progress < startProgress { return .start }
        if progress >= lateProgress { return .late }
        return .mid
    }

    /// Fraction of the Monday→Sunday week elapsed through (and including) today.
    private static func fractionOfWeekElapsed(today: Date) -> Double {
        let cal = Calendar.current
        let weekStart = TrainingVolume.weekStart(of: today)
        let dayIndex = cal.dateComponents([.day], from: weekStart, to: cal.startOfDay(for: today)).day ?? 0
        return Double(min(max(dayIndex, 0), 6) + 1) / 7.0
    }

    // MARK: Small helpers

    private static func delta(_ pmc: PMCResult?, days: Int, _ metric: (PMCPoint) -> Double) -> Int {
        guard let now = pmc?.points.last.map(metric),
              let then = pmc?.value(daysAgo: days, metric) else { return 0 }
        return Int((now - then).rounded())
    }

    private static func trendWord(_ delta: Int) -> String {
        if delta > 1 { return "rising" }
        if delta < -1 { return "falling" }
        return "flat"
    }

    private static func signed(_ n: Int) -> String { n >= 0 ? "+\(n)" : "\(n)" }

    /// Deterministic djb2 hash — `String.hashValue` is per-process randomized,
    /// which would break the cross-launch per-day insight cache.
    private static func stableHash(_ s: String) -> Int {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) ^ UInt64(b) }
        return Int(bitPattern: UInt(truncatingIfNeeded: h))
    }
}

private extension DateFormatter {
    /// "Mon, Jun 29 2026" — the dashboard insight header date.
    static let insightHeader: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, MMM d yyyy"
        return f
    }()
}
