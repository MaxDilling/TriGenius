import Foundation

// MARK: - TSS Calculator (the single place completed-activity TSS is computed)
//
// Replaces Garmin's EPOC `activityTrainingLoad` with a TrainingPeaks-style TSS,
// validated offline in `ref/tss_lab/` (bike power-TSS reproduces Garmin's cycling
// TSS within ~2 on two athletes; run pace-TSS matches an independent run-power
// reference R²0.97). Computed once at ingest and cached on `WorkoutRecord.tss`.
//
// Brand-agnostic by design: it reads ONLY the normalized `detailsJSON` schema
// (below) plus the athlete's `PerformanceSnapshot`. A new watch brand just has to
// fill the same detailsJSON keys — no change here.
//
//   REQUIRED detailsJSON KEYS (the abstraction contract):
//     sport: String                         · duration_minutes: Number
//     hr_zones_seconds: {z1…z5: seconds}    (HR fallback)
//     cycling.normalized_power_w: Number    (bike)
//     running.normalized_pace_s_per_km: Number   (run; normalized, grade-adjusted NGP)
//     swimming.cleaned_distance_m: Number   · swimming.swim_time_s: Number  (swim)
//
// Dispatch: bike → power, run/swim → pace, everything else → HR zone-load. Each
// path falls back to HR zone-load when its inputs/thresholds are missing.

nonisolated enum TSSCalculator {

    /// How a completed activity's TSS was derived — so the UI can tell the athlete
    /// where the number came from (BUGS.md "show where the TSS calculation comes
    /// from"). Mirrors the dispatch in `compute(details:snapshot:)`.
    enum Basis {
        case power, runPace, swimPace, swimDuration, hrZones

        /// Short, athlete-facing provenance label.
        var label: String {
            switch self {
            case .power:        return "normalized power vs FTP"
            case .runPace:      return "normalized pace vs threshold pace"
            case .swimPace:     return "swim pace vs CSS (cleaned distance)"
            case .swimDuration: return "duration × typical swim intensity"
            case .hrZones:      return "heart-rate zone load"
            }
        }
    }

    static func tss(details: [String: Any], snapshot: PerformanceSnapshot) -> Double? {
        compute(details: details, snapshot: snapshot).tss
    }

    /// The TSS value plus how it was derived. `basis` is nil only when no number
    /// could be produced at all (no usable inputs).
    static func compute(details: [String: Any], snapshot: PerformanceSnapshot) -> (tss: Double?, basis: Basis?) {
        let family = SportFamily(sportKey: details["sport"] as? String ?? "other")
        let hours = (Coerce.double(details["duration_minutes"]) ?? 0) / 60.0
        guard hours > 0 else { return (nil, nil) }

        switch family {
        case .bike:
            if let t = powerTSS(details, ftp: snapshot.cyclingFTP, hours: hours) { return (t, .power) }
        case .run:
            if let t = runPaceTSS(details, thresholdPace: snapshot.lactateThrPaceSeconds, hours: hours) { return (t, .runPace) }
        case .swim:
            // Swim resolves either to a CSS-paced score or a duration floor.
            if let (t, basis) = swimResult(details, css: snapshot.cssPaceSeconds, fallbackHours: hours) {
                return (t, basis)
            }
        case .strength, .other:
            break
        }
        // Fallback for any path with missing inputs.
        if let t = hrZoneTSS(details, hours: hours) { return (t, .hrZones) }
        return (nil, nil)
    }

    // MARK: Power (bike)

    private static func powerTSS(_ details: [String: Any], ftp: Int?, hours: Double) -> Double? {
        guard let ftp, ftp > 0,
              let np = Coerce.double(sub(details, "cycling")?["normalized_power_w"]), np > 0
        else { return nil }
        let intensity = clamp(np / Double(ftp))
        return round(intensity * intensity * hours * 100)
    }

    // MARK: Pace (run / swim)

    private static func runPaceTSS(_ details: [String: Any], thresholdPace: Double?, hours: Double) -> Double? {
        guard let thresholdPace, thresholdPace > 0,
              let pace = Coerce.double(sub(details, "running")?["normalized_pace_s_per_km"]), pace > 0
        else { return nil }
        let intensity = clamp(thresholdPace / pace)        // faster pace → higher IF
        return round(intensity * intensity * hours * 100)
    }

    /// Swim sTSS from the CLEANED distance + active swim time, with a duration
    /// floor so slow technique sessions aren't under-scored. Returns the value plus
    /// whether it came from a CSS pace (`.swimPace`) or the duration floor
    /// (`.swimDuration`).
    private static func swimResult(_ details: [String: Any], css: Double?, fallbackHours: Double) -> (Double, Basis)? {
        let swim = sub(details, "swimming")
        let swimTime = Coerce.double(swim?["swim_time_s"])
        // Effective (resolved manual/cleaned/Garmin) distance — set by TSSScoring.
        let distance = Coerce.double(details["distance_km"]).map { $0 * 1000 }
        let hours = (swimTime ?? fallbackHours * 3600) / 3600.0
        guard hours > 0 else { return nil }
        let floor = TSSConstants.swimDefaultIF * TSSConstants.swimDefaultIF * hours * 100

        guard let css, css > 0, let swimTime, swimTime > 0,
              let distance, distance > 0 else { return (round(floor), .swimDuration) }   // floor-only
        let pace = swimTime / (distance / 100.0)           // sec / 100 m
        let intensity = clamp(css / pace)
        let value = round(max(intensity * intensity * hours * 100, floor))
        // If the floor dominated, the CSS pace didn't actually drive the score.
        return (value, value > round(floor) ? .swimPace : .swimDuration)
    }

    // MARK: HR zone-load (fallback)

    private static func hrZoneTSS(_ details: [String: Any], hours: Double) -> Double? {
        guard let zones = details["hr_zones_seconds"] as? [String: Any] else { return nil }
        var load = 0.0
        var any = false
        for (i, frac) in TSSConstants.hrZoneMidFractionOfLTHR.enumerated() {
            guard let secs = Coerce.double(zones["z\(i + 1)"]), secs > 0 else { continue }
            any = true
            load += frac * frac * (secs / 3600.0) * 100
        }
        guard any else { return nil }
        return round(load * TSSConstants.hrZoneLoadScale)
    }

    // MARK: Helpers

    private static func sub(_ d: [String: Any], _ key: String) -> [String: Any]? {
        d[key] as? [String: Any]
    }

    private static func clamp(_ v: Double) -> Double {
        min(max(v, TSSConstants.ifRange.lowerBound), TSSConstants.ifRange.upperBound)
    }
}
