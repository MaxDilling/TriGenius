import Foundation

// MARK: - TSS scoring (shared ingest + recompute path)
//
// Re-derives a completed activity's effective distance and TSS from its stored
// `detailsJSON`, using the current thresholds. Used at ingest (after the data
// source fills detailsJSON) and by the manual distance-override path — so an
// override re-scores in place without re-fetching from the watch; a tuning change
// takes effect on the next per-source re-sync (which re-fetches and re-ingests).
// Brand-agnostic: reads only the detailsJSON schema (see `TSSCalculator`).
//
// Swims are re-cleaned here from their stored per-length data, so changing the
// cleaning constants and recomputing re-derives the corrected distance.

nonisolated enum TSSScoring {

    /// Mutates `details` (swimming.cleaned_distance_m / swim_time_s, distance_km,
    /// time-in-zone) and returns the resolved distance (km) + TSS + how the TSS was
    /// derived (the provenance label surfaced to the athlete/coach; nil when no TSS
    /// was produced). `zoneSamples` are the source's raw streams for this unit; empty
    /// on the recompute path, which re-scores from stored details and has no streams
    /// to re-bucket — the zones already in `details` then stand.
    static func score(_ details: inout [String: Any], snapshot: PerformanceSnapshot,
                      zoneSamples: ZoneSamples) -> (distanceKm: Double, tss: Double?, basis: String?) {
        // 1. Swim: re-clean from the stored active lengths.
        if var swimming = details["swimming"] as? [String: Any],
           let pool = Coerce.double(swimming["pool_length_m"]), pool > 0,
           let raw = swimming["lengths"] as? [[String: Any]], !raw.isEmpty {
            if let cleaned = SwimLengthCleaner.clean(SwimLengthCleaner.lengths(from: raw), poolLengthMeters: pool) {
                swimming["cleaned_distance_m"] = round1(Double(cleaned.cleanedLengthCount) * pool)
                swimming["swim_time_s"] = round1(cleaned.swimTimeSeconds)
                // Overrides Garmin's raw activeLengths so the coach's compact
                // summary (`total_lengths`) agrees with the Lengths card.
                swimming["total_lengths"] = cleaned.cleanedLengthCount
                details["swimming"] = swimming
            }
        }

        // 2. Effective distance: manual override → cleaned → Garmin → existing.
        let swimming = details["swimming"] as? [String: Any]
        let manual: Double? = Coerce.double(details["manual_distance_m"])
        let cleaned: Double? = swimming.flatMap { Coerce.double($0["cleaned_distance_m"]) }
        let garmin: Double? = swimming.flatMap { Coerce.double($0["garmin_distance_m"]) }
        let existing: Double = (Coerce.double(details["distance_km"]) ?? 0) * 1000
        let effectiveM: Double = manual ?? cleaned ?? garmin ?? existing
        let distanceKm = round2(effectiveM / 1000)
        details["distance_km"] = distanceKm

        // 3. Time in zone, bucketed from the source's raw streams against this date's
        // thresholds — one model for every source (`ZoneBucketing`).
        ZoneBucketing.apply(zoneSamples, to: &details, snapshot: snapshot)

        // 4. TSS from the resolved details + current thresholds.
        let (tss, basis) = TSSCalculator.compute(details: details, snapshot: snapshot)
        return (distanceKm, tss, basis?.label)
    }

    /// Scores each leg of a multisport session in place and returns the row
    /// totals. Every leg is a normal single-sport details dict, so each goes
    /// through `score` unchanged — the bike leg gets power TSS, the run leg
    /// rTSS. Row TSS is their sum (nil when no leg scored, e.g. a session that
    /// is only transitions); the basis lists the distinct per-leg bases in
    /// order, so a partly HR-derived total isn't over-trusted.
    static func scoreSegments(_ segments: inout [WorkoutSegment], snapshot: PerformanceSnapshot,
                              zoneSamples: [String: ZoneSamples])
        -> (distanceKm: Double, tss: Double?, basis: String?) {
        var distanceKm = 0.0, total = 0.0, scored = false
        var bases: [String] = []
        for i in segments.indices {
            let legSamples = segments[i].sourceId.flatMap { zoneSamples[$0] } ?? [:]
            let (km, tss, basis) = score(&segments[i].details, snapshot: snapshot, zoneSamples: legSamples)
            segments[i].tss = tss
            segments[i].tssBasis = basis
            distanceKm += km
            if let tss { total += tss; scored = true }
            if let basis, !bases.contains(basis) { bases.append(basis) }
        }
        guard scored else { return (round2(distanceKm), nil, nil) }
        return (round2(distanceKm), round1(total), "segments: " + bases.joined(separator: " + "))
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}
