import Foundation

// MARK: - Weekly Target (Volume)
//
// The per-discipline weekly volume goal ("Wochensoll") the dashboard rings fill
// against. Derived — in priority order — from:
//   1. the athlete's PLANNED workouts for the current week (the scheduled-workout
//      store), summing target duration + TSS per discipline; falling back to
//   2. the current training-plan phase's per-sport weekly TSS target; falling back to
//   3. a heuristic from the athlete's weekly hour budget (`weeklyStructure`)
//      shaped by the current periodisation phase (`trainingPlan`).
//
// This keeps the rings honest: once the coach/Garmin has scheduled the week, the
// goal IS the plan; before that, it's the phase's stated target; and only without
// any plan does it fall back to a heuristic estimate.

struct WeeklyTarget: Sendable {
    /// Target training time for the week, in minutes.
    var durationMinutes: Double
    /// Target TSS for the week (0 = not set yet).
    var tss: Double
    /// Target distance for the week, in km (0 = not applicable, e.g. strength).
    var distanceKm: Double = 0
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

    /// Per-discipline weekly targets for the current week. `scheduled` are the
    /// planned workouts whose date falls in the displayed week; when a discipline
    /// has any, its target is the sum of those (TSS estimated from duration where
    /// missing). Disciplines with no scheduled work use the current plan phase's
    /// stated target, then fall back to the heuristic.
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

        let currentPhase = plan.phase()

        var out: [SportFamily: WeeklyTarget] = [:]
        for family in SportFamily.allCases {
            if let p = planned[family], p.durationMinutes > 0 || p.tss > 0 {
                // Scheduled workouts carry no distance — take the phase's stated
                // weekly distance if any, else estimate from the planned duration.
                let km = phaseTarget(for: family, phase: currentPhase)?.distanceKm
                    ?? estimatedDistanceKm(family: family, minutes: p.durationMinutes).rounded()
                out[family] = WeeklyTarget(durationMinutes: p.durationMinutes, tss: p.tss.rounded(), distanceKm: km)
            } else if let pt = phaseTarget(for: family, phase: currentPhase) {
                out[family] = pt
            } else {
                out[family] = heuristicTarget(for: family, weeklyStructure: weeklyStructure, plan: plan)
            }
        }
        return out
    }
}
