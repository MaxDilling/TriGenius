import Foundation

// MARK: - TSS scoring (shared ingest + recompute path)
//
// Re-derives a completed activity's effective distance and TSS from its stored
// `detailsJSON`, using the current thresholds. Used both at ingest (after the
// data source fills detailsJSON) and by the "recompute all" action — so a tuning
// change or a manual distance override takes effect without re-fetching from the
// watch. Brand-agnostic: reads only the detailsJSON schema (see `TSSCalculator`).
//
// Swims are re-cleaned here from their stored per-length data, so changing the
// cleaning constants and recomputing re-derives the corrected distance.

nonisolated enum TSSScoring {

    /// Mutates `details` (swimming.cleaned_distance_m / swim_time_s, distance_km)
    /// and returns the resolved distance (km) + TSS.
    static func score(_ details: inout [String: Any], snapshot: PerformanceSnapshot) -> (distanceKm: Double, tss: Double?) {
        // 1. Swim: re-clean from the stored active lengths.
        if var swimming = details["swimming"] as? [String: Any],
           let pool = Coerce.double(swimming["pool_length_m"]), pool > 0,
           let raw = swimming["lengths"] as? [[String: Any]], !raw.isEmpty {
            let lengths = raw.map {
                SwimLength(durationSeconds: Coerce.double($0["d"]) ?? 0,
                           strokes: Int(Coerce.double($0["s"]) ?? 0),
                           distanceMeters: Coerce.double($0["m"]) ?? 0)
            }
            if let cleaned = SwimLengthCleaner.clean(lengths, poolLengthMeters: pool) {
                swimming["cleaned_distance_m"] = round1(Double(cleaned.cleanedLengthCount) * pool)
                swimming["swim_time_s"] = round1(cleaned.swimTimeSeconds)
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

        // 3. TSS from the resolved details + current thresholds.
        return (distanceKm, TSSCalculator.tss(details: details, snapshot: snapshot))
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}
