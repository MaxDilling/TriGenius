import Foundation

// MARK: - Workout Normalizer
//
// Source-agnostic layer between the coach's `add_workout` tool call and any
// workout-scheduling backend (currently Garmin). It fills sensible defaults,
// synthesizes an explicit step structure when none is given, and expands
// single/degenerate intensity targets into usable bands — recording every
// adjustment so the result can be reported back to the model transparently.
//
// Keeping all of this here (not in GarminWorkoutBuilder) means the builder only
// translates an already-clean model into Garmin's wire format, and a future
// scheduler (e.g. Amazfit) reuses the exact same normalization. The output dict
// keeps the same snake_case shape the `add_workout` schema defines, so any
// backend can consume it unchanged.

nonisolated enum WorkoutNormalizer {

    /// Offsets applied when the model gives a single / degenerate target value.
    /// Tunable in one place. Pace is asymmetric (athletes tolerate a touch slower
    /// more readily than a touch faster); the others are symmetric.
    enum Band {
        static let paceFasterSeconds = 20.0   // sec/km subtracted -> faster bound
        static let paceSlowerSeconds = 10.0   // sec/km added -> slower bound
        static let heartRateBpm = 4.0
        static let powerFraction = 0.05       // ±5 %
        static let speedFraction = 0.05       // ±5 % (km/h)
        static let cadenceRpm = 3.0
        /// Below this, a "pace" value can't be sec/km (faster than 1:00/km) — most
        /// likely the model sent m/s, so we skip expansion rather than emit garbage.
        static let minPlausiblePaceSeconds = 60.0
    }

    static let swimSportKeys: Set<String> = ["swimming", "swim", "pool_swimming", "lap_swimming"]

    /// Generous plausibility bounds for `add_workouts`/`modify_workout` input — reject
    /// only values that are clearly broken (e.g. a "3 s/km" pace, the bug this guards
    /// against), never values merely outside one athlete's personal fitness (that finer
    /// guard is `TSSConstants.ifRange`, applied only to the TSS *estimate*). Ranges are
    /// deliberately wide enough to cover elite/ultra-endurance targets.
    enum Bounds {
        static let durationMinutes = 1.0 ... 2880.0        // up to 48 h (ultra events)
        static let stepDurationSeconds = 1.0 ... 43_200.0  // up to 12 h in one step
        static let repeatCount = 1 ... 200                 // e.g. 100×25 m swim drill
        static let heartRateBpm = 30.0 ... 230.0

        static func distanceMeters(_ family: SportFamily) -> ClosedRange<Double> {
            switch family {
            case .swim: return 10 ... 50_000
            case .bike: return 100 ... 1_000_000
            case .run:  return 50 ... 300_000
            default:    return 10 ... 1_000_000
            }
        }

        /// Pace unit is seconds per 100 m for swim, seconds per km otherwise.
        static func paceSeconds(_ family: SportFamily) -> ClosedRange<Double> {
            switch family {
            case .swim: return 35 ... 400
            case .run:  return 90 ... 900
            case .bike: return 20 ... 900
            default:    return 60 ... 1200
            }
        }

        static func speedKMH(_ family: SportFamily) -> ClosedRange<Double> {
            switch family {
            case .swim: return 1 ... 9
            case .run:  return 2 ... 40
            case .bike: return 5 ... 80
            default:    return 1 ... 80
            }
        }

        static func powerWatts(_ family: SportFamily) -> ClosedRange<Double> {
            switch family {
            case .bike: return 10 ... 2000
            case .run:  return 10 ... 800
            default:    return 10 ... 2000
            }
        }

        static func cadenceRPM(_ family: SportFamily) -> ClosedRange<Double> {
            switch family {
            case .bike: return 20 ... 220
            case .run:  return 50 ... 220
            case .swim: return 15 ... 100
            default:    return 15 ... 220
            }
        }
    }

    /// Normalize a raw `workout_data` dict from the model. Returns the cleaned dict
    /// (always with an explicit `steps` array), human-readable notes describing every
    /// default and adjustment that was applied, and any plausibility-check failures —
    /// when `errors` is non-empty the caller must reject the whole item rather than
    /// store `workoutData`.
    static func normalize(_ raw: [String: Any]) -> (workoutData: [String: Any], notes: [String], errors: [String]) {
        var data = raw
        var notes: [String] = []
        var errors: [String] = []

        let sport = token(raw["sport"]) ?? "other"
        let isSwim = swimSportKeys.contains(sport)
        let family = SportFamily(sportKey: sport)

        // --- Top-level defaults ---
        if (data["name"] as? String)?.isEmpty ?? true {
            let fallback = defaultName(sport: sport, minutes: Coerce.int(data["duration_minutes"]))
            data["name"] = fallback
            notes.append("Name: defaulted to \"\(fallback)\".")
        }

        if isSwim, data["pool_length"] == nil {
            data["pool_length"] = 50
            notes.append("Pool length: defaulted to 50 m.")
        }

        if let minutes = Coerce.double(data["duration_minutes"]), !Bounds.durationMinutes.contains(minutes) {
            errors.append("duration_minutes \(shortNumber(minutes)) is outside the plausible range (\(shortNumber(Bounds.durationMinutes.lowerBound))–\(shortNumber(Bounds.durationMinutes.upperBound)) min).")
        }
        if let meters = Coerce.double(data["distance_meters"]) {
            let range = Bounds.distanceMeters(family)
            if !range.contains(meters) {
                errors.append("distance_meters \(shortNumber(meters)) is outside the plausible range (\(shortNumber(range.lowerBound))–\(shortNumber(range.upperBound)) m) for \(family.displayName).")
            }
        }

        // --- Steps: synthesize if absent, otherwise normalize the provided ones ---
        let rawSteps = data["steps"] as? [[String: Any]] ?? []
        if rawSteps.isEmpty {
            let (steps, synthNotes) = synthesizeSteps(
                durationMinutes: Coerce.int(data["duration_minutes"]),
                distanceMeters: Coerce.double(data["distance_meters"]),
                includeWarmup: data["include_warmup"] as? Bool ?? true,
                includeCooldown: data["include_cooldown"] as? Bool ?? true,
                isSwim: isSwim
            )
            data["steps"] = steps
            notes.append(contentsOf: synthNotes)
        } else {
            data["steps"] = rawSteps.enumerated().map { i, step in
                normalizeStep(step, label: "Step \(i + 1)", family: family, notes: &notes, errors: &errors)
            }
        }

        return (data, notes, errors)
    }

    // MARK: - Step synthesis (no explicit steps provided)

    private static func synthesizeSteps(durationMinutes: Int?, distanceMeters: Double?, includeWarmup: Bool, includeCooldown: Bool, isSwim: Bool) -> ([[String: Any]], [String]) {
        var steps: [[String: Any]] = []
        var notes: [String] = []

        // Distance-only (no duration): a single distance interval — there is no time
        // budget to split, so no auto warm-up / cool-down.
        if durationMinutes == nil, let distanceMeters {
            steps.append(["type": "interval", "end_condition": "distance", "distance_meters": distanceMeters])
            notes.append("No steps given — built a single \(Int(distanceMeters)) m interval.")
            return (steps, notes)
        }

        var remaining = (durationMinutes ?? 60) * 60

        if includeWarmup && remaining >= 600 {
            let secs = min(remaining / 10, 300)
            steps.append(["type": "warmup", "end_condition": "time", "duration_seconds": secs])
            remaining -= secs
            notes.append("Warm-up: added \(secs / 60) min (default).")
        }

        var cooldownSecs = 0
        if includeCooldown && remaining >= 600 {
            cooldownSecs = min(remaining / 10, 300)
            remaining -= cooldownSecs
        }

        if let distanceMeters, isSwim {
            steps.append(["type": "interval", "end_condition": "distance", "distance_meters": distanceMeters])
        } else {
            steps.append(["type": "interval", "end_condition": "time", "duration_seconds": remaining])
        }

        if cooldownSecs > 0 {
            steps.append(["type": "cooldown", "end_condition": "time", "duration_seconds": cooldownSecs])
            notes.append("Cool-down: added \(cooldownSecs / 60) min (default).")
        }

        notes.append("No steps given — built a warm-up / main / cool-down structure.")
        return (steps, notes)
    }

    // MARK: - Per-step normalization

    private static func normalizeStep(_ raw: [String: Any], label: String, family: SportFamily, notes: inout [String], errors: inout [String]) -> [String: Any] {
        var step = raw
        let type = token(raw["type"]) ?? "interval"
        if raw["type"] == nil { step["type"] = "interval" }

        if type == "repeat" {
            if let count = Coerce.int(raw["repeat_count"]), !Bounds.repeatCount.contains(count) {
                errors.append("\(label) (repeat): repeat_count \(count) is outside the plausible range (\(Bounds.repeatCount.lowerBound)–\(Bounds.repeatCount.upperBound)).")
            }
            if raw["repeat_count"] == nil {
                step["repeat_count"] = 4
                notes.append("\(label) (repeat): repeat_count defaulted to 4.")
            }
            if raw["skip_last_rest"] == nil { step["skip_last_rest"] = true }
            step["repeat_steps"] = (raw["repeat_steps"] as? [[String: Any]] ?? []).enumerated().map { j, child in
                normalizeStep(child, label: "\(label).\(j + 1)", family: family, notes: &notes, errors: &errors)
            }
            return step
        }

        // Resolve the end condition explicitly so the builder never has to infer.
        step["end_condition"] = endCondition(for: raw, type: type)

        validateExtent(step, label: label, family: family, errors: &errors)

        // Expand single / degenerate intensity targets into a band.
        expandTarget(in: &step, label: label, notes: &notes)
        validateTarget(step, label: label, family: family, errors: &errors)
        return step
    }

    // MARK: - Plausibility validation

    private static func validateExtent(_ step: [String: Any], label: String, family: SportFamily, errors: inout [String]) {
        if let secs = Coerce.double(step["duration_seconds"]), !Bounds.stepDurationSeconds.contains(secs) {
            errors.append("\(label): duration_seconds \(shortNumber(secs)) is outside the plausible range (\(shortNumber(Bounds.stepDurationSeconds.lowerBound))–\(shortNumber(Bounds.stepDurationSeconds.upperBound)) s).")
        }
        if let meters = Coerce.double(step["distance_meters"]) {
            let range = Bounds.distanceMeters(family)
            if !range.contains(meters) {
                errors.append("\(label): distance_meters \(shortNumber(meters)) is outside the plausible range (\(shortNumber(range.lowerBound))–\(shortNumber(range.upperBound)) m) for \(family.displayName).")
            }
        }
    }

    /// Validates the step's *final* target_low/target_high — after band expansion,
    /// so an implausible single value that skipped expansion (see
    /// `Band.minPlausiblePaceSeconds`) is still caught, not silently stored.
    private static func validateTarget(_ step: [String: Any], label: String, family: SportFamily, errors: inout [String]) {
        guard let targetType = token(step["target_type"]), targetType != "no_target" else { return }
        let values = [Coerce.double(step["target_low"]), Coerce.double(step["target_high"])].compactMap { $0 }
        guard !values.isEmpty else { return }

        let range: ClosedRange<Double>
        let unit: String
        switch targetType {
        case "pace":       range = Bounds.paceSeconds(family); unit = family == .swim ? "s/100m" : "s/km"
        case "heart_rate": range = Bounds.heartRateBpm; unit = "bpm"
        case "power":      range = Bounds.powerWatts(family); unit = "W"
        case "speed":      range = Bounds.speedKMH(family); unit = "km/h"
        case "cadence":    range = Bounds.cadenceRPM(family); unit = "rpm"
        default: return
        }
        for v in values where !range.contains(v) {
            errors.append("\(label): \(targetType) target \(shortNumber(v)) \(unit) is outside the plausible range (\(shortNumber(range.lowerBound))–\(shortNumber(range.upperBound)) \(unit)) for \(family.displayName).")
        }
    }

    private static func endCondition(for step: [String: Any], type: String) -> String {
        if let ec = token(step["end_condition"]) { return ec }
        if step["distance_meters"] != nil { return "distance" }
        if type == "rest", step["duration_seconds"] != nil { return "fixed_rest" }
        if step["end_on_lap"] as? Bool == true { return "lap_button" }
        return "time"
    }

    // MARK: - Target band expansion

    private static func expandTarget(in step: inout [String: Any], label: String, notes: inout [String]) {
        guard let targetType = token(step["target_type"]), targetType != "no_target" else { return }
        let low = Coerce.double(step["target_low"])
        let high = Coerce.double(step["target_high"])

        // Determine the single center value to expand. An explicit, non-degenerate
        // band (low != high) is left exactly as the model provided it.
        let center: Double?
        if let low, let high {
            center = (low == high) ? low : nil
        } else {
            center = low ?? high
        }

        guard let center else {
            if low == nil && high == nil {
                step["target_type"] = "no_target"
                step.removeValue(forKey: "target_low")
                step.removeValue(forKey: "target_high")
                notes.append("\(label): \(targetType) target had no value — dropped to no_target.")
            }
            return
        }

        guard let (newLow, newHigh, desc) = band(targetType: targetType, center: center) else { return }
        step["target_low"] = newLow
        step["target_high"] = newHigh
        notes.append("\(label): \(desc)")
    }

    private static func band(targetType: String, center: Double) -> (low: Double, high: Double, desc: String)? {
        switch targetType {
        case "pace":
            guard center >= Band.minPlausiblePaceSeconds else { return nil }
            let low = center - Band.paceFasterSeconds   // faster bound (fewer sec/km)
            let high = center + Band.paceSlowerSeconds   // slower bound
            return (low, high, "pace \(paceStr(center)) → \(paceStr(low))–\(paceStr(high))/km (band −\(Int(Band.paceFasterSeconds))/+\(Int(Band.paceSlowerSeconds)) s)")
        case "heart_rate":
            let low = (center - Band.heartRateBpm).rounded()
            let high = (center + Band.heartRateBpm).rounded()
            return (low, high, "HR \(Int(center)) → \(Int(low))–\(Int(high)) bpm")
        case "power":
            let low = (center * (1 - Band.powerFraction)).rounded()
            let high = (center * (1 + Band.powerFraction)).rounded()
            return (low, high, "power \(Int(center)) → \(Int(low))–\(Int(high)) W (±\(Int(Band.powerFraction * 100))%)")
        case "speed":
            let low = round1(center * (1 - Band.speedFraction))
            let high = round1(center * (1 + Band.speedFraction))
            return (low, high, "speed \(round1(center)) → \(low)–\(high) km/h (±\(Int(Band.speedFraction * 100))%)")
        case "cadence":
            let low = (center - Band.cadenceRpm).rounded()
            let high = (center + Band.cadenceRpm).rounded()
            return (low, high, "cadence \(Int(center)) → \(Int(low))–\(Int(high)) rpm")
        default:
            return nil
        }
    }

    // MARK: - Helpers

    /// Lowercase + snake_case a string value; nil/empty -> nil. Mild canonicalization
    /// only (matches the data's snake_case convention), not fuzzy enum matching.
    private static func token(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return Coerce.token(s)
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    private static func shortNumber(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private static func paceStr(_ secPerKm: Double) -> String {
        let total = Int(secPerKm.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func defaultName(sport: String, minutes: Int?) -> String {
        let label = sport.isEmpty ? "Workout" : sport.prefix(1).uppercased() + sport.dropFirst()
        if let minutes { return "\(label) \(minutes) min" }
        return String(label)
    }
}
