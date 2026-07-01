import Foundation

// MARK: - ATP engine (pure)
//
// Turns the period shells + methodology params + sparse overrides into the weekly
// plan, then derives the daily CTL curves via PMCEngine. Both methodologies share ONE
// progressive `loadShape` (base→build climbs `loadProgression` per week, recovery/taper
// dip, pins fixed); they differ only in how its level is set:
//   • weeklyTSS  — scaled so the season mean ≈ weeklyAverageTSS.
//   • targetCTL  — level solved (closed form; CTL is linear in it) so the forward-
//     simulated CTL reaches each event target. Ramp is reported, not enforced.
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

    /// Per-week relative load weight (coefficient on the plan level). Base/build load
    /// rises `loadProgression^k` across a segment (k = active load week, reset per
    /// segment, held across recovery weeks); recovery/taper dip relative to that block
    /// level; peak/race/transition are the light `periodLoad` periods.
    private static func loadShape(_ shells: [ATPWeekShell]) -> [Double] {
        var out = [Double](repeating: 0, count: shells.count)
        var k = 0
        var inSegment = false
        for (i, s) in shells.enumerated() {
            guard s.period.isBaseOrBuild else {
                out[i] = ATPConstants.periodLoad[s.period] ?? 0.20
                inSegment = false
                continue
            }
            if !inSegment { k = 0; inSegment = true }
            else if !s.isRecovery { k += 1 }             // recovery holds the level, doesn't advance it
            let level = pow(ATPConstants.loadProgression, Double(k))
            out[i] = s.isRecovery ? level * ATPConstants.recoveryLoadFactor
                   : s.isTaper ? level * ATPConstants.taperLoadFactor
                   : level
        }
        return out
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
        let shape = loadShape(shells)

        var pinnedSum = 0.0
        var weightSum = 0.0
        for (i, s) in shells.enumerated() {
            if let p = pins[s.weekStart] { pinnedSum += p } else { weightSum += shape[i] }
        }
        let freeBudget = max(0, avg * Double(n) - pinnedSum)

        var tss = [Double](repeating: 0, count: n)
        for (i, s) in shells.enumerated() {
            if let p = pins[s.weekStart] {
                tss[i] = p
            } else if weightSum > 0 {
                let raw = freeBudget * shape[i] / weightSum
                // Race/transition are deliberately light — don't lift them to the easiest floor.
                let floor = (s.period == .race || s.period == .transition) ? 0 : easiest
                tss[i] = min(hardest, max(floor, raw)).rounded()
            }
        }
        return assemble(shells: shells, tss: tss, pins: pins, params: params)
    }

    // MARK: Target-CTL mode

    /// Weekly TSS so the projected CTL **reaches** each event's `targetCTL` — every
    /// target a *lower bound*, not an exact hit.
    ///
    /// The season load is the progressive `loadShape` (base→build climbs `loadProgression`
    /// per week, recovery/taper dip) scaled by a single plan level `L`; pinned weeks are
    /// fixed (rest **or** camp). Weekly CTL is linear in `L`, so `L` is closed-form:
    /// simulate at `L=0` and `L=1`, read CTL at the event week, interpolate to the target.
    /// CTL is only ever forward-simulated (never inverted), so peak/taper/transition weeks
    /// just decay out — no CTL target needed for a falling week. Each event solves its own
    /// plan; the pointwise max keeps the invariant that adding an event only ever *raises*
    /// load (a lower event before a higher one never forces detraining — you train through).
    /// The ramp is a reported consequence; a week over `maxRampRate` is flagged in assemble.
    static func targetCTL(shells: [ATPWeekShell], params: ATPParams, events: [ATPEventInput], overrides: [ATPWeekOverrideInput]) -> [ATPWeekPlan] {
        let pins = pinMap(overrides)
        let beta = weeklyDecay
        let n = shells.count
        let c0 = params.startingCTL ?? 0
        let shape = loadShape(shells)

        // Split each week into level-scaled (α·L) and fixed (β, = a pin) parts. A pinned
        // week is constant; everything else scales with the plan level.
        var alpha = shape, konst = [Double](repeating: 0, count: n)
        for (i, s) in shells.enumerated() where pins[s.weekStart] != nil {
            alpha[i] = 0; konst[i] = pins[s.weekStart]!
        }

        /// Weekly CTL at `aw` for a given plan level (β + α·L spread over the days).
        func ctlAt(_ aw: Int, level: Double) -> Double {
            var c = c0
            for i in 0...aw { c = c * beta + ((konst[i] + alpha[i] * level) / 7) * (1 - beta) }
            return c
        }

        /// One event's weekly TSS: solve the level so CTL hits `target` at its week.
        func eventTSS(anchorWeek aw: Int, target: Double) -> [Double] {
            let base = ctlAt(aw, level: 0)                    // fixed weeks (pins) only
            let span = ctlAt(aw, level: 1) - base             // marginal CTL per unit level (linear)
            let level = span > 1e-9 ? max(0, (target - base) / span) : 0
            return (0..<n).map { konst[$0] + alpha[$0] * level }
        }

        let anchors: [(aw: Int, target: Double)] = events.compactMap { ev in
            guard let t = ev.targetCTL,
                  let wi = shells.firstIndex(where: { $0.weekStart == TrainingVolume.weekStart(of: ev.date) })
            else { return nil }
            return (wi, t)
        }

        // No target set: hold current fitness flat (c0·7 = steady-state TSS). Else pointwise max.
        var tss = anchors.isEmpty ? (0..<n).map { alpha[$0] == 0 ? konst[$0] : c0 * 7 } : [Double](repeating: 0, count: n)
        for (aw, target) in anchors {
            let e = eventTSS(anchorWeek: aw, target: target)
            for i in 0..<n where e[i] > tss[i] { tss[i] = e[i] }     // pointwise max → targets only raise load
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
        // Seed ATL from the actual fatigue at the anchor (else steady-state = CTL), so the
        // plan's Form (TSB = CTL − ATL) starts realistic instead of at +startingCTL.
        let seedATL = history.last(where: { $0.date <= anchorDay })?.atl ?? resolved.startingCTL ?? 0
        let planCurve = PMCEngine.simulate(
            anchorDate: anchorDay, ctl0: resolved.startingCTL ?? 0, atl0: seedATL,
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
