import Foundation

// MARK: - Normalized Stream
//
// The single, source-independent implementation of TrainingPeaks-style stream
// normalization — the math behind Normalized Power and its pace/speed analogue.
// Every data source feeds its raw samples (each with the real duration it covers)
// through THIS function; no source keeps its own copy of the computation (see
// CLAUDE.md "Algorithms are source-independent").

nonisolated enum NormalizedStream {
    /// One stream reading: its `value` and the `seconds` of real time it represents
    /// (its own measurement interval — Apple Health supplies this per sample; a 1 Hz
    /// stream like Garmin's passes 1). Carrying the duration lets the math run on
    /// irregularly-spaced samples directly, with no resampling and no interpolated
    /// (invented) values.
    typealias Sample = (value: Double, seconds: Double)

    /// Normalize a sample stream: a `window`-**second** rolling time-average, raised
    /// to the 4th power, averaged (time-weighted), then 4th-rooted. The 4th-power
    /// weighting biases the result toward the harder segments — the basis of
    /// Normalized Power and the normalized speed/pace used for rTSS.
    ///
    /// The window is real time, not a sample count, so two sources at different sample
    /// rates yield the same number for the same effort. Returns `nil` when the stream
    /// covers less than one window: a normalized value genuinely cannot be computed,
    /// so the caller must leave the field empty rather than substitute a mean (which
    /// would be a different, non-normalized number masquerading as one — see CLAUDE.md
    /// "Never fabricate a missing measurement").
    static func normalized(_ samples: [Sample], window: Double = 30) -> Double? {
        let segs = samples.filter { $0.seconds > 0 }
        let total = segs.reduce(0) { $0 + $1.seconds }
        guard total >= window else { return nil }

        // Trailing `window`-second time-average, evaluated at the end of each segment.
        // `head`/`headConsumed` walk a sliding window over real time (the oldest
        // segment is split when it straddles the window edge); each rolling value
        // contributes to the 4th-power mean weighted by its own segment duration.
        var head = 0
        var headConsumed = 0.0
        var windowSum = 0.0   // Σ value·seconds inside the window
        var windowDur = 0.0   // Σ seconds inside the window (→ window once filled)
        var fourthAccum = 0.0
        var weightAccum = 0.0

        for i in segs.indices {
            windowSum += segs[i].value * segs[i].seconds
            windowDur += segs[i].seconds
            while windowDur > window {
                let overflow = windowDur - window
                let remainingHead = segs[head].seconds - headConsumed
                if remainingHead <= overflow {
                    windowSum -= segs[head].value * remainingHead
                    windowDur -= remainingHead
                    head += 1
                    headConsumed = 0
                } else {
                    windowSum -= segs[head].value * overflow
                    windowDur -= overflow
                    headConsumed += overflow
                }
            }
            // Score only once a full window has accumulated (a real `window`-s average).
            if windowDur >= window - 1e-9 {
                let rolling = windowSum / windowDur
                fourthAccum += pow(rolling, 4) * segs[i].seconds
                weightAccum += segs[i].seconds
            }
        }
        guard weightAccum > 0 else { return nil }
        return pow(fourthAccum / weightAccum, 0.25)
    }

    /// Debug provenance for a stream: the raw `(value, seconds)` samples plus the
    /// staged computation (moving time, time-weighted mean, normalized result).
    /// Source-neutral, so Garmin and HealthKit dump the identical shape into the
    /// debug export. `value`/`seconds` are the exact inputs the normalizer saw.
    static func diagnostics(_ samples: [Sample]) -> [String: Any] {
        let movingSeconds = samples.reduce(0) { $0 + $1.seconds }
        var d: [String: Any] = [
            "sample_count": samples.count,
            "moving_seconds": round2(movingSeconds),
            "sample_values": samples.map { round3($0.value) },
            "sample_seconds": samples.map { round2($0.seconds) },
        ]
        if movingSeconds > 0 {
            d["mean_value"] = round3(samples.reduce(0) { $0 + $1.value * $1.seconds } / movingSeconds)
        }
        if let n = normalized(samples) { d["normalized_value"] = round3(n) }
        return d
    }

    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    private static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}
