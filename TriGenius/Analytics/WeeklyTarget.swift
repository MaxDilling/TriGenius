import Foundation

// MARK: - Weekly Target (Volume)
//
// The per-discipline weekly volume goal ("Wochensoll") the dashboard rings fill
// against. The base goal is the athlete's PLAN:
//   1. the current training-plan phase's per-sport weekly TSS target; falling back to
//   2. a heuristic from the athlete's weekly hour budget (`weeklyStructure`)
//      shaped by the current periodisation phase (`trainingPlan`).
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

    // MARK: Heuristic fallback

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

    /// Volume multiplier applied to the weekly hour budget for the current phase.
    /// `maxHours` is treated as the build-phase ceiling; other phases scale off it.
    private static func phaseMultiplier(_ phase: String?) -> Double {
        switch phase?.lowercased() {
        case .some(let p) where p.contains("taper"):     return 0.55
        case .some(let p) where p.contains("recover"):   return 0.60
        case .some(let p) where p.contains("base"):      return 0.85
        case .some(let p) where p.contains("peak"):      return 1.00
        case .some(let p) where p.contains("build"):     return 1.00
        default:                                         return 0.90
        }
    }

    /// Default weekly hours when the athlete hasn't set a budget yet.
    private static let defaultWeeklyHours = 8.0
    /// Fixed weekly strength target (minutes) — small, phase-independent.
    private static let strengthMinutes = 45.0

    private static func heuristicTarget(for family: SportFamily, weeklyStructure: WeeklyStructure, plan: TrainingPlan) -> WeeklyTarget {
        if family == .strength {
            return WeeklyTarget(durationMinutes: strengthMinutes,
                                tss: estimatedTSS(family: .strength, minutes: strengthMinutes))
        }
        let hours = Double(weeklyStructure.maxHours ?? Int(defaultWeeklyHours))
        let budgetMinutes = hours * 60 * phaseMultiplier(plan.currentPhase)
        let minutes = budgetMinutes * split(family)
        return WeeklyTarget(durationMinutes: minutes.rounded(),
                            tss: estimatedTSS(family: family, minutes: minutes).rounded(),
                            distanceKm: estimatedDistanceKm(family: family, minutes: minutes).rounded())
    }

    /// The current phase's stated weekly target for a discipline. The dashboard
    /// rings fill against TSS, so this only applies when the phase sets a weekly
    /// TSS for the sport; the matching duration is back-estimated from it so the
    /// time-based insight gaps still work, and the weekly distance is taken from
    /// the phase if stated (else estimated from the duration).
    private static func phaseTarget(for family: SportFamily, phase: Phase?) -> WeeklyTarget? {
        guard let phase,
              let target = phase.sportTargets.first(where: { SportFamily(sportKey: $0.key) == family })?.value,
              let tss = target.weeklyTSS, tss > 0 else { return nil }
        let minutes = (Double(tss) / tssPerHour(family) * 60).rounded()
        let km = target.weeklyDistanceKm ?? estimatedDistanceKm(family: family, minutes: minutes).rounded()
        return WeeklyTarget(durationMinutes: minutes, tss: Double(tss), distanceKm: km)
    }

    // MARK: Public API

    /// Per-discipline weekly targets for the current week. The base goal is the
    /// athlete's plan: the current phase's stated weekly target, falling back to a
    /// heuristic off the weekly hour budget. `scheduled` are the planned workouts
    /// whose date falls in the displayed week; they only *raise* the goal — a week
    /// scheduled beyond the plan targets the larger volume. A partially-scheduled
    /// week must NOT pull the goal below the plan, so the target is the per-metric
    /// max of (scheduled sum, plan target). This keeps the ring honest: planning a
    /// single 53-TSS run doesn't shrink a 90-TSS weekly goal down to 53.
    @MainActor
    static func targets(
        scheduled: [ScheduledWorkoutRecord],
        weeklyStructure: WeeklyStructure,
        plan: TrainingPlan
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

        let currentPhase = plan.phase()

        var out: [SportFamily: WeeklyTarget] = [:]
        for family in SportFamily.allCases {
            // The plan's goal for the week: phase target, else heuristic estimate.
            let base = phaseTarget(for: family, phase: currentPhase)
                ?? heuristicTarget(for: family, weeklyStructure: weeklyStructure, plan: plan)

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
