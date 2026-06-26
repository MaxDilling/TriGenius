import Foundation

// MARK: - Swim length cleaning
//
// Garmin over-counts pool lengths (a wall-detection algorithm error; worse on
// older watches — up to ~26% in testing). Given the per-length data, we rejoin
// lengths Garmin wrongly split: flag lengths that are physically impossible
// (faster than any human over a pool length) or fragments (far fewer strokes than
// a full length), then iteratively merge each fragment into its SHORTER neighbour
// (its likely other half), conserving total swim time. The stroke test is
// pool-length-independent, so it still works when the pool length is misconfigured.
//
// Brand-agnostic: operates on a normalized `[SwimLength]`; the data source maps its
// own per-length payload (Garmin `lengthDTOs`) into this shape. Ported & validated
// in `ref/tss_lab/swim.py`.

/// One ACTIVE pool length (rest/idle lengths are excluded by the caller).
struct SwimLength: Sendable {
    let durationSeconds: Double
    let strokes: Int
    /// Garmin's assigned distance for the length (= pool length); used as a fallback.
    let distanceMeters: Double
}

struct SwimCleanResult: Sendable {
    /// Cleaned (rejoined) real-length count.
    let cleanedLengthCount: Int
    /// Total active swim time (Σ length durations) — conserved by merging.
    let swimTimeSeconds: Double
}

nonisolated enum SwimLengthCleaner {

    /// Clean the active lengths of a pool swim. Returns nil when there is no usable
    /// per-length data (caller then keeps Garmin's count / falls back to duration).
    static func clean(_ lengths: [SwimLength], poolLengthMeters: Double) -> SwimCleanResult? {
        guard !lengths.isEmpty, poolLengthMeters > 0 else { return nil }

        let times = lengths.map(\.durationSeconds)
        let tRef = median(times)
        let fullStrokes = lengths
            .filter { $0.durationSeconds > 0 && poolLengthMeters / $0.durationSeconds <= TSSConstants.swimSpeedCeilingMPS }
            .map { Double($0.strokes) }
            .filter { $0 > 0 }
        let sRef = fullStrokes.isEmpty ? 0 : median(fullStrokes)

        // Mutable working segments; merge fragments into the shorter neighbour.
        var segs: [(time: Double, strokes: Int)] = lengths.map { ($0.durationSeconds, $0.strokes) }
        var changed = true
        while changed && segs.count > 1 {
            changed = false
            for i in segs.indices {
                guard isFragment(time: segs[i].time, strokes: segs[i].strokes,
                                 pool: poolLengthMeters, tRef: tRef, sRef: sRef) else { continue }
                let prev = i > 0 ? segs[i - 1].time : .greatestFiniteMagnitude
                let next = i < segs.count - 1 ? segs[i + 1].time : .greatestFiniteMagnitude
                let j = prev <= next ? i - 1 : i + 1
                segs[j].time += segs[i].time
                segs[j].strokes += segs[i].strokes
                segs.remove(at: i)
                changed = true
                break
            }
        }

        return SwimCleanResult(cleanedLengthCount: segs.count,
                               swimTimeSeconds: times.reduce(0, +))
    }

    /// A length that can't be a full pool length: impossibly fast, or far fewer
    /// strokes (or, lacking strokes, far less time) than the session's full length.
    private static func isFragment(time: Double, strokes: Int, pool: Double,
                                   tRef: Double, sRef: Double) -> Bool {
        if time <= 0 || pool / time > TSSConstants.swimSpeedCeilingMPS { return true }
        if sRef > 0 && strokes > 0 {
            return Double(strokes) < TSSConstants.swimFragmentStrokeFraction * sRef
        }
        return time < TSSConstants.swimFragmentTimeFraction * tRef
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
