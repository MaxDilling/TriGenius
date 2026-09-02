import Foundation

// MARK: - Time-in-zone reading & aggregation
//
// The single shared reader of the per-workout zone dicts each metric's
// `ZoneMetric.detailsPath` names ({z1…z5: seconds}, written at ingest by
// `ZoneBucketing`), used by the workout detail view (one activity) and the
// Statistics screen (range aggregate). A record without the metric's key
// contributes nothing — absence stays absence.

enum ZoneDistribution {

    /// `z1…z5` seconds from one details dict, or nil when the metric's key is
    /// absent or all-zero.
    nonisolated static func zoneSeconds(details: [String: Any], metric: ZoneMetric) -> [Double]? {
        guard let dict = section(details, metric)?[metric.detailsPath.seconds] as? [String: Any] else { return nil }
        let zones = (1...5).map { Coerce.double(dict["z\($0)"]) ?? 0 }
        return zones.reduce(0, +) > 0 ? zones : nil
    }

    /// The z1–z4 upper bounds these seconds were bucketed against, in the metric's
    /// own unit — what the UI states a zone *means* for this workout. Nil for a
    /// record ingested before the bounds were stored, or with none recorded.
    nonisolated static func zoneBounds(details: [String: Any], metric: ZoneMetric) -> [Double]? {
        guard let raw = section(details, metric)?[metric.detailsPath.bounds] as? [Any] else { return nil }
        let bounds = raw.compactMap { Coerce.double($0) }
        return bounds.count == 4 ? bounds : nil
    }

    /// The dict a metric's keys live in — the details themselves, or its per-sport
    /// section.
    private nonisolated static func section(_ details: [String: Any], _ metric: ZoneMetric) -> [String: Any]? {
        guard let name = metric.detailsPath.section else { return details }
        return details[name] as? [String: Any]
    }

    /// Element-wise sum of `z1…z5` across the records that carry the metric's key;
    /// `[]` when none does. `family` selects the discipline — applied per details
    /// dict, so only the matching *leg* of a multisport session counts.
    @MainActor
    static func aggregate(records: [WorkoutRecord], metric: ZoneMetric, family: SportFamily) -> [Double] {
        var total: [Double]? = nil
        for details in records.flatMap(\.detailDicts) {
            guard SportFamily(sportKey: details["sport"] as? String ?? "other") == family,
                  let zones = zoneSeconds(details: details, metric: metric) else { continue }
            total = zip(total ?? [0, 0, 0, 0, 0], zones).map(+)
        }
        return total ?? []
    }
}
