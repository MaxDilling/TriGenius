import Foundation

// MARK: - ATP engine (pure)
//
// Turns the period shells + methodology params + sparse overrides into the weekly
// plan, then derives the daily CTL curves via PMCEngine. Both methodologies share
// ONE per-week shape weight (period × recovery × taper); they differ only in how
// that shape is scaled:
//   • weeklyTSS  — scaled so the season mean ≈ weeklyAverageTSS.
//   • targetCTL  — scaled per segment so the projected CTL hits each event target.
// CTL is daily (never on the weekly row); the table samples the curve at week-end.

/// One week of the finished plan. No CTL fields — those live in `ATPPlan`'s curves.
struct ATPWeekPlan: Sendable, Identifiable {
    let weekStart: Date
    var id: Date { weekStart }
    let period: ATPPeriod
    let periodWeekIndex: Int
    let isRecovery: Bool
    let isTaper: Bool
    let plannedTSS: Double
    let rampRate: Double          // ΔCTL vs the previous week (from the plan curve)
    let rampExceeded: Bool        // ramp climbs faster than params.maxRampRate (TP's unsustainable-ramp flag)
    let pinned: Bool
    let weeksToNextEvent: Int?
    let nextEventID: String?
}

/// The full derived ATP the UI renders: the weekly grid plus the three daily CTL
/// curves (all from `PMCEngine` with different input) and the events for markers.
struct ATPPlan: Sendable {
    let weeks: [ATPWeekPlan]
    let planCurve: [PMCPoint]         // follow the ATP, anchored at (startDate, startingCTL)
    let detrainingCurve: [PMCPoint]   // if the athlete stops training (decay from today)
    let actualCurve: [PMCPoint]       // from completed activities
    /// Completed TSS bucketed by week (Monday) — the "done" bars over the plan.
    let completedTSSByWeek: [Date: Double]
    let events: [ATPEventInput]
}

enum ATPEngine {

    // MARK: Shared shape + weekly EWMA

    /// 7-day decay — the closed form of `PMCEngine`'s daily CTL EWMA, so the
    /// back-solver shares the single time constant rather than re-deriving it.
    private static var weeklyDecay: Double {
        let alpha = 1 - exp(-1 / PMCEngine.ctlTimeConstant)
        return pow(1 - alpha, 7)
    }

    /// Per-week base load weight from period × recovery × taper.
    private static func shape(_ s: ATPWeekShell) -> Double {
        var f = ATPConstants.periodLoad[s.period] ?? 1
        if s.isRecovery { f *= ATPConstants.recoveryLoadFactor }
        if s.isTaper && s.period != .race && s.period != .peak { f *= ATPConstants.taperLoadFactor }
        return f
    }

    /// End-of-week CTL per week from weekly TSS (TSS spread evenly across 7 days):
    /// `C_w = C_{w-1}·β + (T_w / 7)(1 − β)`.
    private static func forwardWeeklyCTL(tss: [Double], c0: Double, beta: Double) -> [Double] {
        var c = c0
        return tss.map { t in c = c * beta + (t / 7) * (1 - beta); return c }
    }

    private static func pinMap(_ overrides: [ATPWeekOverrideInput]) -> [Date: Double] {
        Dictionary(overrides.map { (TrainingVolume.weekStart(of: $0.weekStart), $0.pinnedTSS) },
                   uniquingKeysWith: { _, last in last })
    }

    // MARK: Weekly-TSS mode

    /// Distribute the season budget by shape weight; pins are fixed and the free
    /// weeks absorb the slack (pin one week low → the neighbours rise to hold the
    /// average). Clamped to the easiest/hardest bounds.
    static func weeklyTSS(shells: [ATPWeekShell], params: ATPParams, overrides: [ATPWeekOverrideInput]) -> [ATPWeekPlan] {
        let pins = pinMap(overrides)
        let avg = params.weeklyAverageTSS
        let easiest = avg * ATPConstants.easiestFraction
        let hardest = avg * ATPConstants.hardestFraction
        let n = shells.count

        var pinnedSum = 0.0
        var weightSum = 0.0
        for s in shells {
            if let p = pins[s.weekStart] { pinnedSum += p } else { weightSum += shape(s) }
        }
        let freeBudget = max(0, avg * Double(n) - pinnedSum)

        var tss = [Double](repeating: 0, count: n)
        for (i, s) in shells.enumerated() {
            if let p = pins[s.weekStart] {
                tss[i] = p
            } else if weightSum > 0 {
                let raw = freeBudget * shape(s) / weightSum
                // Race/transition are deliberately light — don't lift them to the easiest floor.
                let floor = (s.period == .race || s.period == .transition) ? 0 : easiest
                tss[i] = min(hardest, max(floor, raw)).rounded()
            }
        }
        return assemble(shells: shells, tss: tss, pins: pins, params: params)
    }

    // MARK: Target-CTL mode

    /// Back-solve the weekly TSS so the projected CTL **reaches** each event's
    /// `targetCTL` — treating every target as a *lower bound*, not an exact hit.
    ///
    /// The plan is the pointwise max of each target's standalone ramp-then-maintain
    /// plan (ramp from the start CTL to the target by its week, then hold it). Taking
    /// the max guarantees the invariant the athlete expects: adding an event can only
    /// ever *raise* a week's load, never lower it — so a lower-CTL event placed before
    /// a higher-CTL one never forces detraining "down to" it (you train through it).
    /// Priority is irrelevant here; an A or B target behaves the same.
    static func targetCTL(shells: [ATPWeekShell], params: ATPParams, events: [ATPEventInput], overrides: [ATPWeekOverrideInput]) -> [ATPWeekPlan] {
        let pins = pinMap(overrides)
        let beta = weeklyDecay
        let k = (1 - beta) / 7
        let n = shells.count
        let c0 = params.startingCTL ?? 0
        func maintain(_ ctl: Double, _ i: Int) -> Double { ctl * 7 * (ATPConstants.periodLoad[shells[i].period] ?? 0.5) }

        let anchors: [(aw: Int, target: Double)] = events.compactMap { ev in
            guard let t = ev.targetCTL,
                  let wi = shells.firstIndex(where: { $0.weekStart == TrainingVolume.weekStart(of: ev.date) })
            else { return nil }
            return (wi, t)
        }

        var tss = [Double](repeating: 0, count: n)
        if anchors.isEmpty {
            // No target set: maintain current fitness, shaped by the period.
            for i in 0..<n { tss[i] = maintain(c0, i) }
        }
        for (aw, target) in anchors {
            // Scale the free weeks in [0...aw] so CTL hits `target` ramping from c0:
            // C_aw = c0·β^(aw+1) + Σ coeff_i·T_i ,  coeff_i = k·β^(aw−i).
            var fixed = c0 * pow(beta, Double(aw + 1))
            var freeContribution = 0.0
            for i in 0...aw {
                let coeff = k * pow(beta, Double(aw - i))
                if let p = pins[shells[i].weekStart] { fixed += coeff * p }
                else { freeContribution += coeff * shape(shells[i]) }
            }
            let scale = freeContribution > 0 ? max(0, (target - fixed) / freeContribution) : 0
            for i in 0..<n {
                let v = i <= aw ? scale * shape(shells[i]) : maintain(target, i)
                if v > tss[i] { tss[i] = v }     // pointwise max → targets only raise load
            }
        }

        // Pins are hard overrides; everything else rounds.
        for i in 0..<n { tss[i] = (pins[shells[i].weekStart] ?? tss[i]).rounded() }
        return assemble(shells: shells, tss: tss, pins: pins, params: params)
    }

    // MARK: Assembly + daily spread

    private static func assemble(shells: [ATPWeekShell], tss: [Double], pins: [Date: Double], params: ATPParams) -> [ATPWeekPlan] {
        let ctl = forwardWeeklyCTL(tss: tss, c0: params.startingCTL ?? 0, beta: weeklyDecay)
        var prev = params.startingCTL ?? 0
        var out: [ATPWeekPlan] = []
        for (i, s) in shells.enumerated() {
            let ramp = ctl[i] - prev
            prev = ctl[i]
            out.append(ATPWeekPlan(
                weekStart: s.weekStart, period: s.period, periodWeekIndex: s.periodWeekIndex,
                isRecovery: s.isRecovery, isTaper: s.isTaper, plannedTSS: tss[i], rampRate: ramp,
                rampExceeded: params.maxRampRate > 0 && ramp > params.maxRampRate,
                pinned: pins[s.weekStart] != nil,
                weeksToNextEvent: s.weeksToNextEvent, nextEventID: s.nextEventID))
        }
        return out
    }

    /// Spread each week's planned TSS evenly across its 7 days — the input to the
    /// plan-CTL curve. Reconciled with reality the way `WeeklyTargets` does: where a
    /// week already has real scheduled/completed TSS beyond the ATP budget, the
    /// larger total wins (`max`), so the near-term forecast and the far-term plan
    /// agree instead of double-counting.
    static func dailyPlannedTSS(weeks: [ATPWeekPlan], scheduled: [Date: Double] = [:]) -> [Date: Double] {
        let cal = Calendar.current
        var out: [Date: Double] = [:]
        for w in weeks {
            let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: w.weekStart) }
            let weekSched = days.reduce(0.0) { $0 + (scheduled[cal.startOfDay(for: $1)] ?? 0) }
            let share = max(w.plannedTSS, weekSched) / 7
            for d in days { out[cal.startOfDay(for: d)] = share }
        }
        return out
    }

    // MARK: Build

    /// Compose the full plan: layout → solve (by methodology) → daily CTL curves.
    /// Pure. Returns nil when there's nothing to periodize toward (no A/B event).
    static func build(
        params: ATPParams,
        events: [ATPEventInput],
        overrides: [ATPWeekOverrideInput],
        history: [PMCPoint],
        scheduled: [Date: Double] = [:],
        completedTSSByWeek: [Date: Double] = [:],
        today: Date = Date()
    ) -> ATPPlan? {
        let perf = Perf.begin("ATPEngine.build"); defer { Perf.end(perf) }
        let shells = ATPPeriodization.layout(params: params, events: events, today: today)
        guard !shells.isEmpty else { return nil }

        // Resolve the seed CTL: explicit, else the actual CTL on the anchor day.
        let resolved: ATPParams
        if params.startingCTL == nil {
            let anchorDay = TrainingVolume.weekStart(of: params.startDate)
            let seed = history.last(where: { $0.date <= anchorDay })?.ctl ?? history.first?.ctl ?? 0
            resolved = ATPParams(startDate: params.startDate, startingCTL: seed, methodology: params.methodology,
                                 recoveryCycle: params.recoveryCycle, maxRampRate: params.maxRampRate,
                                 weeklyAverageTSS: params.weeklyAverageTSS)
        } else {
            resolved = params
        }

        let weeks: [ATPWeekPlan]
        switch resolved.methodology {
        case .weeklyTSS: weeks = weeklyTSS(shells: shells, params: resolved, overrides: overrides)
        case .targetCTL: weeks = targetCTL(shells: shells, params: resolved, events: events, overrides: overrides)
        }

        let cal = Calendar.current
        guard let lastWeek = weeks.last?.weekStart else { return nil }
        // Curves run a few weeks past the last event so the post-event detraining /
        // "Not-Set" decay is visible (the plan bars stop at the event).
        let lastEventWeek = events.filter { $0.priority != .c }
            .map { TrainingVolume.weekStart(of: $0.date) }.max() ?? lastWeek
        let tailEnd = cal.date(byAdding: .weekOfYear, value: ATPConstants.chartTailWeeks, to: lastEventWeek) ?? lastWeek
        guard let horizon = cal.date(byAdding: .day, value: 6, to: max(tailEnd, lastWeek)) else { return nil }

        let anchorDay = TrainingVolume.weekStart(of: resolved.startDate)
        let planCurve = PMCEngine.simulate(
            anchorDate: anchorDay, ctl0: resolved.startingCTL ?? 0,
            dailyTSS: dailyPlannedTSS(weeks: weeks, scheduled: scheduled), through: horizon)

        let todayDay = cal.startOfDay(for: today)
        let ctlNow = history.last(where: { $0.date <= todayDay })?.ctl ?? history.last?.ctl ?? 0
        let detraining = PMCEngine.decay(fromDate: todayDay, ctl0: ctlNow, through: horizon)

        return ATPPlan(weeks: weeks, planCurve: planCurve, detrainingCurve: detraining,
                       actualCurve: history, completedTSSByWeek: completedTSSByWeek, events: events)
    }

    /// Read the store + the actual PMC and build the current plan. Mirrors
    /// `PMCEngine.current` / `WeeklyTargets.targets`. Nil when no ATP exists yet.
    @MainActor
    static func current(store: TrainingDataStore? = nil, today: Date = Date()) -> ATPPlan? {
        let store = store ?? .shared
        guard let params = store.atpParams() else { return nil }
        let history = PMCEngine.current(store: store, today: today, forecastDays: 0).points
        // Completed TSS per week, for the "done" bars over the plan.
        var completed: [Date: Double] = [:]
        if let first = history.first?.date {
            for d in store.dailyTSS(from: first, to: today) {
                completed[TrainingVolume.weekStart(of: d.date), default: 0] += d.totalTSS
            }
        }
        return build(params: params, events: store.atpEvents(), overrides: store.atpOverrides(),
                     history: history, completedTSSByWeek: completed, today: today)
    }

    // MARK: Helpers

    /// TP "Estimate Starting Fitness": weekly training hours × sport factor (Appendix
    /// A) → seed CTL. `sport` is one of "cyclist" / "triathlete" / "runner".
    static func estimateStartingCTL(weeklyHours: Double, sport: String) -> Double {
        let perHour = ATPConstants.startingCTLPerHour[sport.lowercased()]
            ?? ATPConstants.startingCTLPerHour["triathlete"]!
        return (weeklyHours * perHour).rounded()
    }
}
