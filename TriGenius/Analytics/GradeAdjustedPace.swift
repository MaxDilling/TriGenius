import Foundation

// MARK: - Grade-Adjusted Pace (true NGP)
//
// The single, source-independent grade model behind Normalized Graded Pace — the
// running refinement of the normalized speed used for rTSS. A run on a gradient costs
// more (uphill) or less (gentle downhill) energy than the same pace on the flat, so the
// raw pace under-rates a hilly effort. This converts each speed sample into the
// EQUIVALENT FLAT-GROUND speed before the 4th-power normalization runs.
//
// Every source feeds its own (speed, grade) samples through THIS function; no source
// carries its own copy of the adjustment (see CLAUDE.md "Algorithms are
// source-independent"). The result is `NormalizedStream.Sample`s, so it drops straight
// into `NormalizedStream.normalized`.

enum GradeAdjustedPace {
    /// Metabolic cost of running vs gradient, normalized to the flat cost — the factor
    /// that turns an actual speed at `grade` (rise/run fraction) into the equivalent
    /// flat speed. From Minetti et al. (2002) energy-cost polynomial, the standard
    /// public stand-in for TrainingPeaks' proprietary NGP curve: `factor(0) == 1`
    /// (flat / grade-less streams are unchanged), > 1 uphill, < 1 on a gentle descent,
    /// rising again on a steep one. `grade` is clamped to ±0.30 so a GPS/altimeter
    /// spike can't blow up the cost.
    static func gradeFactor(_ grade: Double) -> Double {
        let i = min(max(grade, -0.30), 0.30)
        let cost = ((((155.4 * i - 30.4) * i - 43.3) * i + 46.3) * i + 19.5) * i + 3.6
        return cost / 3.6
    }

    /// Grade-adjust a (speed, grade) stream into normalized-stream samples: each
    /// sample's speed becomes its equivalent flat speed, keeping the real duration it
    /// covers so the time-weighted normalization is unaffected.
    static func adjusted(_ samples: [(speed: Double, grade: Double, seconds: Double)]) -> [NormalizedStream.Sample] {
        samples.map { (value: $0.speed * gradeFactor($0.grade), seconds: $0.seconds) }
    }

    /// Gradient (rise/run) at each point by central difference over ~`window` horizontal
    /// metres — the shared de-noising every source feeds raw altitude through before the
    /// cost factor. Raw per-sample Δaltitude/Δrun is noisy (GPS/barometer), and because
    /// `gradeFactor` is convex, symmetric noise rectifies into a systematic UPWARD bias;
    /// differencing over a fixed horizontal span removes it while preserving real terrain
    /// (validated against the athlete's heart rate — see ref/tss_lab). `distance` is
    /// cumulative horizontal metres (monotonic), `altitude` aligned to it; both equal
    /// length. A point whose window spans < 1 m gets grade 0. Garmin's pre-smoothed
    /// `directGrade`, when present, skips this and is used directly.
    static func smoothedGrades(distance: [Double], altitude: [Double], window: Double = 12) -> [Double] {
        let n = distance.count
        guard n > 0, altitude.count == n else { return Array(repeating: 0, count: n) }
        var grades = Array(repeating: 0.0, count: n)
        var lo = 0, hi = 0
        for i in 0..<n {
            while lo < i && distance[i] - distance[lo] > window { lo += 1 }
            while hi < n - 1 && distance[hi] - distance[i] < window { hi += 1 }
            let run = distance[hi] - distance[lo]
            grades[i] = run > 1 ? (altitude[hi] - altitude[lo]) / run : 0
        }
        return grades
    }
}
