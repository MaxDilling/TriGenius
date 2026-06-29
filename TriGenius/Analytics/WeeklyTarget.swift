import Foundation

// MARK: - Weekly Target (Volume)
//
// The per-discipline weekly volume goal ("Wochensoll") the dashboard rings fill
// against. The base goal is the athlete's PLAN:
//   1. the ATP's weekly TSS for the week, divided across disciplines by
//      `ATPSportSplit` (the athlete's ratio + floors from `WeeklyStructure`);
//      falling back to
//   2. a heuristic from the athlete's weekly hour budget (`weeklyStructure`) when
//      there is no ATP yet.
// PLANNED workouts for the week (the scheduled-workout store) then only *raise*
// the goal — a week scheduled beyond the plan targets the larger volume — but a
// partially-scheduled week never pulls it below the plan.
//
// This keeps the rings honest: the goal is the plan, scheduling more commits to
// more, and planning a single light session doesn't shrink the weekly target.

struct WeeklyTarget: Sendable {
    /// Target training time for the week, in minutes.
    var durationMinutes: Double
    /// Target TSS for the week (0 = not set yet).
    var tss: Double
    /// Target distance for the week, in km (0 = not applicable, e.g. strength).
    var distanceKm: Double = 0
}

/// How a discipline's week is expected to close: what's already completed plus
/// what's still planned for the remaining days. The dashboard ring renders the
/// projection as a faded continuation of the actual arc; the proactive coach
/// compares it against the target to flag an at-risk week.
struct WeeklyProjection: Sendable {
    /// Completed so far this week.
    var actualTSS: Double = 0
    var actualKm: Double = 0
    /// Completed + still-planned for the remaining days (today excluded — today's
    /// load is already in `actual`, matching the PMC forecast which starts at
    /// tomorrow). Equals `actual` when nothing remains planned.
    var projectedTSS: Double = 0
    var projectedKm: Double = 0
}

enum WeeklyTargets {

    // MARK: TSS estimation

    /// Rough TSS accrued per hour for a discipline, used to fill in a TSS target
    /// when a planned workout only specifies a duration (no structured steps for an
    /// intensity-based estimate — see `PlannedTSS`), or for the heuristic fallback.
    /// Derived from the same default intensity model so the flat fallback and the
    /// structured estimate stay consistent: 1 h at IF ⇒ IF² × 100 TSS.
    static func tssPerHour(_ family: SportFamily) -> Double {
        let f = PlannedTSS.defaultIF(family)
        return f * f * 100
    }

    /// Estimate TSS from a duration when no explicit value is available.
    static func estimatedTSS(family: SportFamily, minutes: Double) -> Double {
        minutes / 60 * tssPerHour(family)
    }

    // MARK: Distance estimation

    /// Typical average speed (km/h) per discipline, used to back-estimate a weekly
    /// distance target when only a duration/TSS goal is known. Strength has none.
    private static func kmPerHour(_ family: SportFamily) -> Double {
        switch family {
        case .swim:     return 3
        case .bike:     return 28
        case .run:      return 10
        default:        return 0
        }
    }

    /// Estimate weekly distance (km) from a duration target.
    static func estimatedDistanceKm(family: SportFamily, minutes: Double) -> Double {
        minutes / 60 * kmPerHour(family)
    }

    // MARK: Heuristic fallback (no ATP yet)

    /// Fraction of the weekly triathlon time budget that goes to each discipline
    /// (a classic ~20/50/30 swim/bike/run split). Strength is a small fixed add.
    private static func split(_ family: SportFamily) -> Double {
        switch family {
        case .swim: return 0.20
        case .bike: return 0.50
        case .run:  return 0.30
        default:    return 0
        }
    }

    /// Flat volume multiplier on the weekly hour budget when there's no ATP to
    /// shape the week — `maxHours` is a ceiling, so the everyday goal sits below it.
    private static let heuristicVolumeFactor = 0.90
    /// Default weekly hours when the athlete hasn't set a budget yet.
    private static let defaultWeeklyHours = 8.0
    /// Fixed weekly strength target (minutes) — small, sits outside the ATP TSS budget.
    private static let strengthMinutes = 45.0

    private static func heuristicTarget(for family: SportFamily, weeklyStructure: WeeklyStructure) -> WeeklyTarget {
        let hours = Double(weeklyStructure.maxHours ?? Int(defaultWeeklyHours))
        let minutes = hours * 60 * heuristicVolumeFactor * split(family)
        return WeeklyTarget(durationMinutes: minutes.rounded(),
                            tss: estimatedTSS(family: family, minutes: minutes).rounded(),
                            distanceKm: estimatedDistanceKm(family: family, minutes: minutes).rounded())
    }

    // MARK: ATP-fed base goal

    /// The week's base per-discipline goal. When the ATP sets a weekly TSS for the
    /// week, divide it across swim/bike/run by the athlete's ratio + floors
    /// (`ATPSportSplit`) and back-estimate each discipline's duration/distance from
    /// its TSS; otherwise fall back to the hour-budget heuristic. Strength sits
    /// outside the ATP triathlon TSS budget as a small fixed target.
    private static func baseTargets(weeklyStructure: WeeklyStructure, atpWeekTSS: Double?) -> [SportFamily: WeeklyTarget] {
        var out: [SportFamily: WeeklyTarget] = [
            .strength: WeeklyTarget(durationMinutes: strengthMinutes,
                                    tss: estimatedTSS(family: .strength, minutes: strengthMinutes)),
            .other: WeeklyTarget(durationMinutes: 0, tss: 0)
        ]
        if let total = atpWeekTSS, total > 0 {
            let dist = ATPSportSplit.split(weeklyTSS: total, ratio: weeklyStructure.sportRatio, floors: weeklyStructure.sportFloors)
            for family in SportFamily.triathlon {
                let tss = dist[family] ?? 0
                let minutes = (tss / tssPerHour(family) * 60).rounded()
                out[family] = WeeklyTarget(durationMinutes: minutes, tss: tss.rounded(),
                                           distanceKm: estimatedDistanceKm(family: family, minutes: minutes).rounded())
            }
        } else {
            for family in SportFamily.triathlon {
                out[family] = heuristicTarget(for: family, weeklyStructure: weeklyStructure)
            }
        }
        return out
    }

    // MARK: Public API

    /// Per-discipline weekly targets for the reference week. The base goal is the
    /// athlete's plan: the ATP's weekly TSS split across disciplines, falling back to
    /// a heuristic off the weekly hour budget when no ATP exists. `scheduled` are the
    /// planned workouts whose date falls in the displayed week; they only *raise* the
    /// goal — a week scheduled beyond the plan targets the larger volume. A partially
    /// scheduled week must NOT pull the goal below the plan, so the target is the
    /// per-metric max of (scheduled sum, plan target). This keeps the ring honest:
    /// planning a single 53-TSS run doesn't shrink a 90-TSS weekly goal down to 53.
    @MainActor
    static func targets(
        scheduled: [WorkoutRecord],
        weeklyStructure: WeeklyStructure,
        atpPlan: ATPPlan?,
        referenceDate: Date = Date()
    ) -> [SportFamily: WeeklyTarget] {
        var planned: [SportFamily: WeeklyTarget] = [:]
        for w in scheduled {
            let family = SportFamily(sportKey: w.sport)
            let tss = w.targetTSS ?? estimatedTSS(family: family, minutes: w.targetDurationMinutes)
            var t = planned[family] ?? WeeklyTarget(durationMinutes: 0, tss: 0)
            t.durationMinutes += w.targetDurationMinutes
            t.tss += tss
            t.distanceKm += (w.plannedDistance?.meters ?? 0) / 1000
            planned[family] = t
        }

        let weekStart = TrainingVolume.weekStart(of: referenceDate)
        let atpWeekTSS = atpPlan?.weeks.first { $0.weekStart == weekStart }?.plannedTSS
        let base = baseTargets(weeklyStructure: weeklyStructure, atpWeekTSS: atpWeekTSS)

        var out: [SportFamily: WeeklyTarget] = [:]
        for family in SportFamily.allCases {
            let base = base[family] ?? WeeklyTarget(durationMinutes: 0, tss: 0)

            guard let p = planned[family], p.durationMinutes > 0 || p.tss > 0 else {
                out[family] = base
                continue
            }
            // Scheduling raises the goal but never lowers it below the plan.
            let minutes = max(p.durationMinutes, base.durationMinutes)
            let tss = max(p.tss, base.tss).rounded()
            // Scheduled workouts carry their own (structured or estimated) distance;
            // the goal is the larger of the plan's stated distance and what's planned.
            let km = max(base.distanceKm, p.distanceKm).rounded()
            out[family] = WeeklyTarget(durationMinutes: minutes, tss: tss, distanceKm: km)
        }
        return out
    }

    // MARK: Projection (expected week close)

    /// Per-discipline projection for the current week: what's been completed plus
    /// what's still planned for the days that remain (today included). Reads the
    /// store directly so both the dashboard ring and the background proactive
    /// check share one rule. Planned workouts on PAST days are excluded (they can
    /// no longer be done as scheduled — a skipped session must not inflate the
    /// projection); a workout planned for today is excluded only if a session of
    /// the same discipline was already completed today, to avoid double-counting
    /// the same effort once it's been logged.
    @MainActor
    static func projection(
        store: TrainingDataStore,
        today: Date = Date()
    ) -> [SportFamily: WeeklyProjection] {
        let cal = Calendar.current
        let weekStart = TrainingVolume.weekStart(of: today)
        let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let todayStart = cal.startOfDay(for: today)

        var out: [SportFamily: WeeklyProjection] = [:]

        // Completed so far this week.
        let weekCompleted = store.activities(from: weekStart, to: weekEnd)
        for record in weekCompleted {
            let family = SportFamily(sportKey: record.sport)
            var p = out[family] ?? WeeklyProjection()
            p.actualTSS += TSS.value(for: record) ?? 0
            p.actualKm += record.distanceKm
            out[family] = p
        }

        // Still-planned for today + the remaining days. `openScheduledWorkouts`
        // drops plans whose completion has landed, so a done session isn't
        // double-counted against the projection.
        let stillPlanned = store.openScheduledWorkouts(from: weekStart, to: weekEnd)
        for w in stillPlanned {
            let day = cal.startOfDay(for: w.date)
            let family = SportFamily(sportKey: w.sport)
            if day < todayStart { continue }                                   // past: can't still be done
            var p = out[family] ?? WeeklyProjection()
            p.projectedTSS += w.targetTSS ?? estimatedTSS(family: family, minutes: w.targetDurationMinutes)
            if let d = w.plannedDistance { p.projectedKm += d.meters / 1000 }
            out[family] = p
        }

        // Fold the completed actuals into the projected totals.
        for (family, var p) in out {
            p.projectedTSS += p.actualTSS
            p.projectedKm += p.actualKm
            out[family] = p
        }
        return out
    }
}
