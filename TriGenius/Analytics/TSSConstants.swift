import Foundation

// MARK: - TSS tuning constants (single source of truth)
//
// Every tunable used by the TSS engine lives here so the model can be adjusted in
// one place (see FEATURES.md "Zentrale Konstanten"). All values were calibrated
// offline against real data in `ref/tss_lab/` (validated on two athletes); the
// lab file names are noted next to each group.
//
// Brand-agnostic: these are physiology/algorithm constants, not Garmin specifics.

nonisolated enum TSSConstants {

    // MARK: Intensity-factor model (shared by PlannedTSS + completed pace/power)

    /// Plausible IF bounds — guards bad targets / thresholds from absurd load.
    static let ifRange = 0.30 ... 1.30

    /// Typical IF for an otherwise-unknown session of a discipline. Squared ×100
    /// this is also the per-hour TSS of the duration-only fallback. Recalibrated
    /// from realized whole-session IF (`ref/tss_lab/tss_planned.py`).
    static func defaultIF(_ family: SportFamily) -> Double {
        switch family {
        case .swim:     return 0.63   // was 0.80
        case .bike:     return 0.71   // was 0.80
        case .run:      return 0.84
        case .strength: return 0.69   // was 0.60
        case .other:    return 0.52   // was 0.72
        }
    }

    /// IF for a step with no resolvable target, by step type (PlannedTSS).
    static func typeDefaultIF(_ typeKey: String, family: SportFamily) -> Double {
        switch typeKey {
        case "warmup", "warm-up", "warm_up",
             "cooldown", "cool-down", "cool_down": return 0.55
        case "rest":     return 0.40
        case "recovery": return 0.50
        default:         return defaultIF(family)
        }
    }

    // MARK: Planned cycling variability uplift
    //
    // A planned power target is an *average*, but realized TSS uses normalized
    // power (NP/avg ≈ 1.30). The closed-loop proved the formula is exact when fed
    // NP; with avg-power targets it under-reads. Applied to resolved bike power IF.
    // Bracket 1.00 (finely structured) … 1.14 (single block). `ref/tss_lab` PORTING.
    static let plannedBikeIFUplift = 1.10

    // MARK: HR zone-load fallback (completed activities without power/pace)
    //
    // Garmin %LTHR zone midpoints → an IF²-weighted load, then a calibrated scale
    // so it reproduces power-TSS on cycling. `ref/tss_lab/tss_completed.py`.
    static let hrZoneMidFractionOfLTHR: [Double] = [0.74, 0.84, 0.89, 0.94, 1.03]
    static let hrZoneLoadScale = 0.77

    // MARK: HR zone boundaries (time-in-zone bucketing for sources without zones)
    //
    // Upper %LTHR bounds for zones 1–4 (zone 5 is open-ended), taken as the
    // midpoints between adjacent zone-load fractions above — so bucketing and
    // scoring share one model. Used when a source (e.g. Apple Health) provides an
    // HR stream but no time-in-zone, so we bucket it against the athlete's LTHR.
    static let hrZoneUpperFractionsOfLTHR: [Double] = zip(hrZoneMidFractionOfLTHR,
                                                          hrZoneMidFractionOfLTHR.dropFirst())
        .map { ($0 + $1) / 2 }

    // MARK: Swimming
    //
    // Length cleaning (`ref/tss_lab/swim.py`) + sTSS duration floor.
    static let swimSpeedCeilingMPS = 1.3     // no pool length faster than this
    static let swimFragmentStrokeFraction = 0.65   // strokes < 65% of full-length median
    static let swimFragmentTimeFraction = 0.60     // fallback when strokes missing
    /// Floor IF for very slow technique/drill swims (pace-IF collapses there but
    /// time in the water is still load); ≈ 40 TSS/h.
    static let swimDefaultIF = 0.63
}
