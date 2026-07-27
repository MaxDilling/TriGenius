import Foundation

// MARK: - Multisport segments
//
// A triathlon or brick is one `WorkoutRecord` whose legs live here: an ordered
// list of sub-activities, each carrying a details dict shaped exactly like a
// single-sport row's `detailsJSON`. That identity is the point — every consumer
// (TSS scoring, zone distribution, the detail view's metric rows) runs the same
// code on a segment as on a whole workout, so a brick's bike leg scores power
// TSS and its run leg rTSS with no parallel implementation.
//
// A transition segment carries duration only; it has no measured distance or
// intensity, so it stays empty rather than being filled with a stand-in.

// Not `Sendable`: `details` is a `[String: Any]` JSON dict. Segments cross
// isolation boundaries encoded, as `segmentsJSON`.
nonisolated struct WorkoutSegment {
    /// Start offset from the parent workout's start, in seconds.
    var offsetSeconds: Double
    /// The provider's id for this leg (`"garmin:<childId>"`, a HealthKit activity
    /// uuid) — provenance only. Nil for a segment the parent implies (a gap).
    var sourceId: String?
    /// Scored by `TSSScoring.scoreSegments`; nil when this leg isn't scorable.
    var tss: Double?
    var tssBasis: String?
    /// A single-sport details dict — same schema as `WorkoutRecord.detailsJSON`.
    var details: [String: Any]
    /// This leg's own `WorkoutStreams` blob. The parent's stream can't stand in:
    /// it carries one cadence series for the whole session, in the units of
    /// whichever discipline the watch happened to record (steps/min), so a bike
    /// leg sliced out of it charts running cadence.
    var streamsData: Data = Data()

    var sport: String { details["sport"] as? String ?? "other" }
    var family: SportFamily { SportFamily(sportKey: sport) }
    /// T1/T2 — carries duration only, and both sources spell it `transition`.
    var isTransition: Bool { sport.contains("transition") }
    var durationMinutes: Double { Coerce.double(details["duration_minutes"]) ?? 0 }
    var distanceKm: Double { Coerce.double(details["distance_km"]) ?? 0 }
}

nonisolated enum WorkoutSegments {

    /// `[{offset_s, source_id, tss, tss_basis, details, streams}]`; "" for no
    /// segments. `streams` is the lzfse blob base64'd, so the whole session stays
    /// one JSON string attribute.
    static func encode(_ segments: [WorkoutSegment]) -> String {
        guard !segments.isEmpty else { return "" }
        let array: [Any] = segments.map { s in
            var obj: [String: Any] = ["offset_s": s.offsetSeconds, "details": s.details]
            if let id = s.sourceId { obj["source_id"] = id }
            if let tss = s.tss { obj["tss"] = tss }
            if let basis = s.tssBasis { obj["tss_basis"] = basis }
            if !s.streamsData.isEmpty { obj["streams"] = s.streamsData.base64EncodedString() }
            return obj
        }
        return String(compactJSON: array)
    }

    static func decode(_ json: String) -> [WorkoutSegment] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.map { obj in
            WorkoutSegment(
                offsetSeconds: Coerce.double(obj["offset_s"]) ?? 0,
                sourceId: obj["source_id"] as? String,
                tss: Coerce.double(obj["tss"]),
                tssBasis: obj["tss_basis"] as? String,
                details: obj["details"] as? [String: Any] ?? [:],
                streamsData: (obj["streams"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
            )
        }
    }
}

extension WorkoutRecord {
    /// The legs of a multisport session; empty for a single-sport row.
    var segments: [WorkoutSegment] { WorkoutSegments.decode(segmentsJSON) }

    /// The single-sport details dicts this record holds — its own, or one per leg
    /// for a multisport session (whose parent details carry no per-discipline
    /// data). What every reader of the `detailsJSON` schema iterates.
    var detailDicts: [[String: Any]] {
        let legs = segments
        guard legs.isEmpty else { return legs.map(\.details) }
        guard let data = detailsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return [obj]
    }

    /// What this record contributes to each sport — itself for a single-sport
    /// row, one entry per leg for a multisport session. **The** entry point for
    /// any per-sport aggregation, so every reader stays a single loop.
    var sportContributions: [(family: SportFamily, tss: Double, distanceKm: Double, durationMinutes: Double)] {
        let legs = segments
        guard !legs.isEmpty else {
            return [(SportFamily(sportKey: sport), tss ?? 0, distanceKm, durationMinutes)]
        }
        return legs.map { ($0.family, $0.tss ?? 0, $0.distanceKm, $0.durationMinutes) }
    }
}
