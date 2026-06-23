import Foundation

// MARK: - Planned TSS (intensity-based estimation for FUTURE workouts)
//
// Completed activities get their TSS from the source (see `TSS.swift`). PLANNED
// workouts have no measured load, so we estimate it. The naive estimate
// (`WeeklyTargets.estimatedTSS`) assumes one flat intensity per discipline, which
// treats a recovery jog and a threshold session identically and runs
// systematically low for quality work.
//
// This computes a proper estimate from the workout's STRUCTURE when it exists.
// For each step we derive an intensity factor (IF) from its target relative to
// the athlete's threshold (FTP / threshold pace / CSS / LTHR) and accumulate the
// TrainingPeaks-standard contribution:
//
//     stepTSS = IF² × (seconds / 3600) × 100      (1 h at threshold ⇒ 100 TSS)
//
// Both ingest paths feed the SAME compact step shape (see `CoachTools` add_workout
// and `GarminService.getCalendar`): a list of dicts with `type`,
// `duration_seconds` or `distance_meters`, optional `target_type`/`target_low`/
// `target_high`, and `repeat_count`/`repeat_steps` for repeat blocks. Pace targets
// are always expressed in seconds (sec/km for run, sec/100 m for swim) by the time
// they reach here. The default-IF model is also the single source of truth for the
// flat duration-only fallback in `WeeklyTargets`.

enum PlannedTSS {

    // MARK: Default intensity model (single source of truth)

    /// Typical intensity factor for an otherwise-unknown session of a discipline.
    /// Squared and ×100 this also yields the per-hour TSS used by the flat
    /// duration-only fallback (`WeeklyTargets.tssPerHour`), so the two estimates
    /// stay consistent.
    static func defaultIF(_ family: SportFamily) -> Double {
        TSSConstants.defaultIF(family)
    }

    /// IF for a step that carries no resolvable target, by step type. Work steps
    /// fall back to the discipline default; warmups/cooldowns/rest are easier.
    private static func typeDefaultIF(_ typeKey: String, family: SportFamily) -> Double {
        TSSConstants.typeDefaultIF(typeKey, family: family)
    }

    /// Typical speed (m/s) per discipline, to convert a distance-based step into a
    /// duration when the step has no pace target to derive speed from.
    private static func defaultSpeedMPS(_ family: SportFamily) -> Double {
        switch family {
        case .swim: return 100.0 / 95.0      // ~1:35 / 100 m
        case .bike: return 28_000.0 / 3600.0 // 28 km/h
        case .run:  return 10_000.0 / 3600.0 // 10 km/h
        default:    return 2.0
        }
    }

    /// Plausible IF bounds — guards against bad targets / thresholds producing
    /// absurd contributions.
    private static let ifRange = TSSConstants.ifRange

    // MARK: Normalized step

    struct RawStep {
        var typeKey: String
        /// `endValue` is meters when `isDistance`, else seconds.
        var isDistance: Bool
        var endValue: Double
        /// "power" | "pace" | "heart_rate" | nil
        var targetType: String?
        /// power: watts · pace: seconds (sec/km run, sec/100 m swim) · hr: bpm
        var targetLow: Double?
        var targetHigh: Double?
    }

    // MARK: Public API

    /// Estimate planned TSS from compact step dicts, or nil when no step carries a
    /// usable intensity target (the caller then keeps the duration heuristic).
    static func estimate(compactSteps: [[String: Any]], family: SportFamily, thresholds: PerformanceSnapshot) -> Double? {
        estimate(rawSteps: flatten(compactSteps), family: family, thresholds: thresholds)
    }

    static func estimate(rawSteps: [RawStep], family: SportFamily, thresholds: PerformanceSnapshot) -> Double? {
        guard !rawSteps.isEmpty else { return nil }
        var total = 0.0
        var anyResolvedTarget = false
        for step in rawSteps {
            let (ifValue, resolved) = intensity(for: step, family: family, thresholds: thresholds)
            if resolved { anyResolvedTarget = true }
            let secs = durationSeconds(for: step, family: family, thresholds: thresholds)
            guard secs > 0 else { continue }
            total += ifValue * ifValue * (secs / 3600.0) * 100.0
        }
        guard anyResolvedTarget, total > 0 else { return nil }
        return total.rounded()
    }

    // MARK: Total distance (display)

    /// Estimated total distance in meters for a planned workout, summing the
    /// distance of every leaf step (expanding repeats). Distance-based steps use
    /// their meters directly; time-based steps are converted via their pace target
    /// when present, else the discipline's default speed. Nil when there are no
    /// measurable steps. Used to show a "~16 km" figure for distance disciplines.
    static func totalDistanceMeters(compactSteps: [[String: Any]], family: SportFamily) -> Double? {
        let raw = flatten(compactSteps)
        guard !raw.isEmpty else { return nil }
        var meters = 0.0
        for step in raw {
            if step.isDistance {
                meters += max(0, step.endValue)
            } else {
                let speed = paceSpeedMPS(for: step, family: family) ?? defaultSpeedMPS(family)
                meters += max(0, step.endValue) * speed
            }
        }
        return meters > 0 ? meters : nil
    }

    // MARK: Step → duration

    private static func durationSeconds(for step: RawStep, family: SportFamily, thresholds: PerformanceSnapshot) -> Double {
        guard step.isDistance else { return max(0, step.endValue) }
        let meters = max(0, step.endValue)
        let speed = paceSpeedMPS(for: step, family: family) ?? defaultSpeedMPS(family)
        guard speed > 0 else { return 0 }
        return meters / speed
    }

    /// Speed (m/s) implied by a pace-targeted step, if any.
    private static func paceSpeedMPS(for step: RawStep, family: SportFamily) -> Double? {
        guard step.targetType == "pace", let pace = midpoint(step.targetLow, step.targetHigh), pace > 0 else { return nil }
        switch family {
        case .swim: return 100.0 / pace   // pace is sec / 100 m
        default:    return 1000.0 / pace  // pace is sec / km
        }
    }

    // MARK: Step → intensity factor

    /// Returns the step's IF and whether it was resolved from a real target
    /// (vs a type default). Only resolved targets make a workout "intensity-based".
    private static func intensity(for step: RawStep, family: SportFamily, thresholds: PerformanceSnapshot) -> (Double, Bool) {
        let fallback = typeDefaultIF(step.typeKey, family: family)
        guard let target = step.targetType, let mid = midpoint(step.targetLow, step.targetHigh), mid > 0 else {
            return (fallback, false)
        }
        switch target {
        case "power":
            let ftp: Double? = family == .bike ? thresholds.cyclingFTP.map(Double.init)
                             : family == .run  ? thresholds.runningFTP.map(Double.init)
                             : nil
            guard let ftp, ftp > 0 else { return (fallback, false) }
            // Planned power targets are averages; realized TSS uses NP (NP/avg ≈ VI).
            // Apply a small variability uplift to bike power targets (see TSSConstants).
            let uplift = family == .bike ? TSSConstants.plannedBikeIFUplift : 1.0
            return (clamp(mid / ftp * uplift), true)
        case "pace":
            let thr: Double? = family == .run  ? thresholds.lactateThrPaceSeconds
                             : family == .swim ? thresholds.cssPaceSeconds
                             : nil
            guard let thr, thr > 0 else { return (fallback, false) }
            return (clamp(thr / mid), true)   // faster pace (smaller seconds) ⇒ higher IF
        case "heart_rate":
            guard let lthr = thresholds.lactateThrHR.map(Double.init), lthr > 0 else { return (fallback, false) }
            return (clamp(mid / lthr), true)
        default:
            return (fallback, false)
        }
    }

    // MARK: Helpers

    private static func midpoint(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case let (x?, y?): return (x + y) / 2
        case let (x?, nil): return x
        case let (nil, y?): return y
        default: return nil
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, ifRange.lowerBound), ifRange.upperBound)
    }

    // MARK: Compact dict → RawStep (handles repeat blocks)

    /// Flatten compact step dicts into leaf `RawStep`s, expanding repeat blocks
    /// (`repeat_count` × `repeat_steps`). Both the Garmin adapter and the coach's
    /// `add_workout` payload carry repeat blocks; recursion expands nested ones.
    private static func flatten(_ steps: [[String: Any]]) -> [RawStep] {
        var out: [RawStep] = []
        for step in steps {
            if let children = step["repeat_steps"] as? [[String: Any]] {
                let count = max(1, Coerce.double(step["repeat_count"]).map { Int($0) } ?? 1)
                let leaves = flatten(children)
                for _ in 0 ..< count { out.append(contentsOf: leaves) }
            } else if let leaf = leaf(from: step) {
                out.append(leaf)
            }
        }
        return out
    }

    private static func leaf(from step: [String: Any]) -> RawStep? {
        let typeKey = (step["type"] as? String)?.lowercased() ?? "interval"
        let isDistance: Bool
        let endValue: Double
        if let meters = Coerce.double(step["distance_meters"]) {
            isDistance = true
            endValue = meters
        } else if let secs = Coerce.double(step["duration_seconds"]) {
            isDistance = false
            endValue = secs
        } else {
            return nil   // no measurable extent → can't contribute
        }
        var targetType = step["target_type"] as? String
        if targetType == "no_target" || targetType == "cadence" { targetType = nil }
        return RawStep(
            typeKey: typeKey,
            isDistance: isDistance,
            endValue: endValue,
            targetType: targetType,
            targetLow: Coerce.double(step["target_low"]),
            targetHigh: Coerce.double(step["target_high"])
        )
    }
}
