import Foundation

// MARK: - HR zone derivation & time-in-zone bucketing
//
// Some sources (Apple Health) expose a heart-rate stream but no time-in-zone, the
// input the HR-zone TSS fallback needs. This derives the athlete's zone boundaries
// from their thresholds and buckets a HR stream into z1…z5 seconds — so a HealthKit
// workout without power/pace can still be scored on heart rate, like a Garmin one.
//
// The boundaries are %LTHR (`TSSConstants.hrZoneUpperFractionsOfLTHR`), so they
// bracket the same zone-load midpoints the scorer uses. Requires a real measured
// LTHR — without it the zones (and the HR-zone TSS that depends on them) are left
// absent rather than estimated from max HR (a guessed threshold; see CLAUDE.md
// "Never fabricate a missing measurement").

nonisolated enum HRZones {

    /// Upper bpm bounds for zones 1–4 (zone 5 open-ended), or nil when the athlete's
    /// measured LTHR is unknown for the activity's date.
    static func upperBounds(snapshot: PerformanceSnapshot) -> [Double]? {
        guard let l = snapshot.lactateThrHR, l > 0 else { return nil }
        let lthr = Double(l)
        return TSSConstants.hrZoneUpperFractionsOfLTHR.map { $0 * lthr }
    }

    /// Bucket a HR point-stream into `{z1…z5: seconds}`, weighting each sample by the
    /// gap to the next (capped, so a recording pause isn't counted as time in zone).
    /// Returns nil when there are no samples or nothing landed in any zone.
    static func timeInZoneSeconds(_ samples: [HeartRateSample], upperBounds: [Double]) -> [String: Double]? {
        guard !samples.isEmpty, upperBounds.count == 4 else { return nil }
        let sorted = samples.sorted { $0.date < $1.date }
        var zones = [Double](repeating: 0, count: 5)
        let gapCapSeconds = 30.0
        for i in sorted.indices {
            let weight: Double = i + 1 < sorted.count
                ? min(max(sorted[i + 1].date.timeIntervalSince(sorted[i].date), 0), gapCapSeconds)
                : 1
            let bpm = sorted[i].bpm
            let zone = upperBounds.firstIndex { bpm <= $0 } ?? 4
            zones[zone] += weight
        }
        guard zones.reduce(0, +) > 0 else { return nil }
        return ["z1": zones[0], "z2": zones[1], "z3": zones[2], "z4": zones[3], "z5": zones[4]]
    }
}
