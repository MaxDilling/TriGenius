import Foundation

// MARK: - Weekly Target (Volume)
//
// The per-discipline weekly volume goal ("Wochensoll") the dashboard rings fill
// against. Derived — in priority order — from:
//   1. the athlete's PLANNED workouts for the current week (the scheduled-workout
//      store), summing target duration + TSS per discipline; falling back to
//   2. a heuristic from the athlete's weekly hour budget (`weeklyStructure`)
//      shaped by the current periodisation phase (`trainingPlan`).
//
// This keeps the rings honest: once the coach/Garmin has scheduled the week, the
// goal IS the plan; before that, it's a sensible phase-aware estimate.

struct WeeklyTarget: Sendable {
    /// Target training time for the week, in minutes.
    var durationMinutes: Double
    /// Target TSS for the week (0 = not set yet).
    var tss: Double
}

enum WeeklyTargets {

    // MARK: TSS estimation

    /// Rough TSS accrued per hour for a discipline, used to fill in a TSS target
    /// when a planned workout only specifies a duration, or for the heuristic
    /// fallback. Triathlon disciplines differ in typical metabolic cost per hour.
    static func tssPerHour(_ family: SportFamily) -> Double {
        switch family {
        case .swim:     return 55
        case .bike:     return 60
        case .run:      return 70
        case .strength: return 30
        case .other:    return 50
        }
    }

    /// Estimate TSS from a duration when no explicit value is available.
    static func estimatedTSS(family: SportFamily, minutes: Double) -> Double {
        minutes / 60 * tssPerHour(family)
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
                            tss: estimatedTSS(family: family, minutes: minutes).rounded())
    }

    // MARK: Public API

    /// Per-discipline weekly targets for the current week. `scheduled` are the
    /// planned workouts whose date falls in the displayed week; when a discipline
    /// has any, its target is the sum of those (TSS estimated from duration where
    /// missing). Disciplines with no scheduled work fall back to the heuristic.
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
            planned[family] = t
        }

        var out: [SportFamily: WeeklyTarget] = [:]
        for family in SportFamily.allCases {
            if let p = planned[family], p.durationMinutes > 0 || p.tss > 0 {
                out[family] = WeeklyTarget(durationMinutes: p.durationMinutes, tss: p.tss.rounded())
            } else {
                out[family] = heuristicTarget(for: family, weeklyStructure: weeklyStructure, plan: plan)
            }
        }
        return out
    }
}
