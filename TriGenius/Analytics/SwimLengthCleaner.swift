import Foundation

// MARK: - Swim length cleaning
//
// Garmin's wall-turn detection errs in both directions. Over-count (worse on older
// watches — up to ~26% in testing): a real length is wrongly split into two too-short
// fragments — flagged as physically impossible (faster than any human over a pool
// length) or far fewer strokes than a full length, then iteratively merged into the
// SHORTER neighbour (its likely other half), conserving total swim time. Under-count:
// a missed wall-turn folds two (or more) real lengths into one over-long recording —
// flagged as far more time/strokes than a full length, then split into that many
// even pieces, conserving total swim time the same way. The stroke test is
// pool-length-independent, so both still work when the pool length is misconfigured.
//
// Brand-agnostic: operates on a normalized `[SwimLength]`; the data source maps its
// own per-length payload (Garmin `lengthDTOs`) into this shape. The over-count
// direction is ported & validated in `ref/tss_lab/swim.py`; the under-count
// (merged-length) direction was validated directly against real per-length FIT data
// in `ref/testdata/` (no impossibly-fast/short false positives across 6 real swims,
// clean separation between plausible lengths at ≤1.17× the median and merged ones
// at ≥1.87×).

/// One ACTIVE pool length (rest/idle lengths are excluded by the caller).
struct SwimLength: Sendable {
    let durationSeconds: Double
    let strokes: Int
    /// Garmin's assigned distance for the length (= pool length); used as a fallback.
    let distanceMeters: Double
}

struct SwimCleanResult: Sendable {
    /// One cleaned (possibly rejoined or split) real length.
    struct Length: Sendable, Equatable {
        let durationSeconds: Double
        let strokes: Int
        /// = pool length: one cleaned length is exactly one pool traversal.
        let distanceMeters: Double
        /// True when a wrongly-split fragment was merged into this length.
        let absorbedFragment: Bool
        /// True when this is one piece of a length that was actually N real
        /// lengths recorded as one (a missed wall-turn), recovered by splitting.
        let splitFromMerged: Bool
    }
    let lengths: [Length]
    /// Cleaned (rejoined/split) real-length count.
    nonisolated var cleanedLengthCount: Int { lengths.count }
    /// Total active swim time (Σ length durations) — conserved by merging/splitting.
    let swimTimeSeconds: Double
}

nonisolated enum SwimLengthCleaner {

    /// The stored `swimming.lengths` dicts (`d`/`s`/`m`) → the cleaner's input —
    /// the single parser, so every caller feeds the cleaner identical data.
    static func lengths(from raw: [[String: Any]]) -> [SwimLength] {
        raw.map {
            SwimLength(durationSeconds: Coerce.double($0["d"]) ?? 0,
                       strokes: Int(Coerce.double($0["s"]) ?? 0),
                       distanceMeters: Coerce.double($0["m"]) ?? 0)
        }
    }

    /// Clean the active lengths of a pool swim. Returns nil when there is no usable
    /// per-length data (caller then keeps Garmin's count / falls back to duration).
    static func clean(_ lengths: [SwimLength], poolLengthMeters: Double) -> SwimCleanResult? {
        guard !lengths.isEmpty, poolLengthMeters > 0 else { return nil }
        let (tRef, sRef) = reference(lengths, poolLengthMeters: poolLengthMeters)
        return cleanCore(lengths, poolLengthMeters: poolLengthMeters, tRef: tRef, sRef: sRef)
    }

    /// Clean several lap-grouped length lists at once, sharing one reference
    /// (`tRef`/`sRef`) computed across every group combined — so a short lap's
    /// stats stay robust — while merges/splits never cross a lap/rest boundary.
    /// One result per input group, same order; nil when there's no usable data at all.
    static func cleanGrouped(_ groups: [[SwimLength]], poolLengthMeters: Double) -> [SwimCleanResult]? {
        let all = groups.flatMap { $0 }
        guard !all.isEmpty, poolLengthMeters > 0 else { return nil }
        let (tRef, sRef) = reference(all, poolLengthMeters: poolLengthMeters)
        return groups.map { cleanCore($0, poolLengthMeters: poolLengthMeters, tRef: tRef, sRef: sRef) }
    }

    /// The full-length reference stats: `tRef` = median duration, `sRef` = median
    /// stroke count over the plausibly-full (not impossibly-fast) lengths.
    private static func reference(_ lengths: [SwimLength], poolLengthMeters: Double) -> (tRef: Double, sRef: Double) {
        let tRef = median(lengths.map(\.durationSeconds))
        let fullStrokes = lengths
            .filter { $0.durationSeconds > 0 && poolLengthMeters / $0.durationSeconds <= TSSConstants.swimSpeedCeilingMPS }
            .map { Double($0.strokes) }
            .filter { $0 > 0 }
        let sRef = fullStrokes.isEmpty ? 0 : median(fullStrokes)
        return (tRef, sRef)
    }

    /// Split merged lengths into their real pieces, then merge fragments into their
    /// shorter neighbour — both against the same shared reference, within this one
    /// group only (a group is one lap: merges/splits never reach into another lap).
    private static func cleanCore(_ lengths: [SwimLength], poolLengthMeters: Double,
                                  tRef: Double, sRef: Double) -> SwimCleanResult {
        guard !lengths.isEmpty else { return SwimCleanResult(lengths: [], swimTimeSeconds: 0) }

        var segs: [(time: Double, strokes: Int, absorbedFragment: Bool, splitFromMerged: Bool)] = []
        for length in lengths {
            guard let n = mergedCount(time: length.durationSeconds, strokes: length.strokes,
                                      tRef: tRef, sRef: sRef) else {
                segs.append((length.durationSeconds, length.strokes, false, false))
                continue
            }
            let baseStrokes = length.strokes / n
            let remainder = length.strokes % n
            for i in 0 ..< n {
                segs.append((length.durationSeconds / Double(n),
                            baseStrokes + (i < remainder ? 1 : 0), false, true))
            }
        }

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
                segs[j].absorbedFragment = true
                segs.remove(at: i)
                changed = true
                break
            }
        }

        return SwimCleanResult(
            lengths: segs.map {
                .init(durationSeconds: $0.time, strokes: $0.strokes, distanceMeters: poolLengthMeters,
                      absorbedFragment: $0.absorbedFragment, splitFromMerged: $0.splitFromMerged)
            },
            swimTimeSeconds: lengths.map(\.durationSeconds).reduce(0, +))
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

    /// A length that's actually N ≥ 2 real lengths recorded as one (a missed
    /// wall-turn): far more time than the session's full length, and — whenever
    /// strokes are available — far more strokes too (both must agree; a genuinely
    /// slow/hard length could satisfy just one). Returns N, or nil when plausible
    /// as a single length.
    private static func mergedCount(time: Double, strokes: Int, tRef: Double, sRef: Double) -> Int? {
        guard tRef > 0 else { return nil }
        let timeIsLong = time > TSSConstants.swimMergedTimeMultiple * tRef
        let strokesAgree = sRef > 0 && strokes > 0
            ? Double(strokes) > TSSConstants.swimMergedStrokeMultiple * sRef
            : true
        guard timeIsLong && strokesAgree else { return nil }
        return max(2, Int((time / tRef).rounded()))
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
