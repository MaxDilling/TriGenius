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

    /// Assumed IF for an untargeted planned step (and, squared ×100, the per-hour
    /// TSS of the duration-only fallback). For the pace disciplines (swim/run) the
    /// IF model is a linear speed ratio, so this is simultaneously the assumed
    /// speed as a fraction of threshold speed — the SAME constant converts a
    /// step's time↔distance and scores its TSS, so a planned workout's estimated
    /// duration, distance and TSS can never contradict each other. Run/bike/
    /// strength/other calibrated from realized whole-session IF
    /// (`ref/tss_lab/tss_planned.py`); swim set to 90% of CSS speed (pool
    /// sessions are swum close to CSS, rests included in the step time).
    static func assumedIF(_ family: SportFamily) -> Double {
        switch family {
        case .swim:     return 0.90
        case .bike:     return 0.71
        case .run:      return 0.84
        case .strength: return 0.69
        case .other:    return 0.52
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

    // MARK: Zone boundaries (time-in-zone bucketing — see `ZoneMetric.upperBounds`)
    //
    // Upper bounds for zones 1–4 as a fraction of the athlete's threshold; zone 5 is
    // open-ended. Every source's stream is bucketed against these, so the boundaries
    // are the app's own — never a provider's zone configuration.

    /// %LTHR, taken as the midpoints between adjacent zone-load fractions above — so
    /// bucketing and HR scoring share one model.
    static let hrZoneUpperFractionsOfLTHR: [Double] = zip(hrZoneMidFractionOfLTHR,
                                                          hrZoneMidFractionOfLTHR.dropFirst())
        .map { ($0 + $1) / 2 }

    /// Fraction of threshold SPEED for running (the axis rises with intensity, unlike
    /// pace). Friel's running pace zones as published by TrainingPeaks ("Setting Pace
    /// Zones (Running)"), using their speed percentages: z1 <78%, z2 →88%, z3 →94%,
    /// z4 →101%, z5a 100–103%, z5b →111%, z5c above. Zones 5a–c collapse into one z5,
    /// and the z4/z5a overlap the published table carries (101% vs 100%) resolves at
    /// threshold itself: z5 is what is run at or above threshold speed, which is what
    /// the 5a–c subdivisions are subdivisions OF.
    ///
    /// Unlike the HR fractions above, these are the literature model — not calibrated
    /// against athlete data in `ref/tss_lab/`.
    static let paceZoneUpperFractionsOfThresholdSpeed: [Double] = [0.78, 0.88, 0.94, 1.00]

    /// Fraction of FTP for cycling: Coggan's classic power zones, whose top three
    /// (VO2max / anaerobic / neuromuscular) collapse into one z5 the same way the
    /// running 5a–c do. Literature model, uncalibrated here.
    static let powerZoneUpperFractionsOfFTP: [Double] = [0.55, 0.75, 0.90, 1.05]

    // MARK: Swimming
    //
    // Length cleaning (`ref/tss_lab/swim.py`) + sTSS duration floor.
    static let swimSpeedCeilingMPS = 1.3     // no pool length faster than this
    static let swimFragmentStrokeFraction = 0.65   // strokes < 65% of full-length median
    static let swimFragmentTimeFraction = 0.60     // fallback when strokes missing
    /// Missed wall-turn (two-plus real lengths recorded as one) — BOTH time and
    /// strokes must exceed this multiple of the full-length median (conservative:
    /// either signal alone could be a genuinely slow/hard length). Validated against
    /// real per-length FIT data: plausible single lengths never exceed 1.17× the
    /// median on either measure, genuinely merged ones start at 1.87×.
    static let swimMergedStrokeMultiple = 1.6      // strokes > 160% of full-length median
    static let swimMergedTimeMultiple = 1.6        // time > 160% of full-length median
    /// Floor IF for very slow technique/drill swims (pace-IF collapses there but
    /// time in the water is still load); ≈ 40 TSS/h.
    static let swimDefaultIF = 0.63
}
