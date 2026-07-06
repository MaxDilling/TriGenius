import Foundation

// MARK: - Time-in-zone parsing & aggregation
//
// The single shared reader of the per-workout zone dicts (`hr_zones_seconds`,
// `cycling.power_zones_seconds` — {z1…z5: seconds} in `detailsJSON`), used by the
// workout detail view (one activity) and the Statistics screen (range aggregate).
// A record without the source's key contributes nothing — absence stays absence.

nonisolated enum ZoneSource: String, Codable, CaseIterable {
    case heartRate
    case power
}

enum ZoneDistribution {

    /// `z1…z5` seconds from one details dict, or nil when the source's key is
    /// absent or all-zero.
    nonisolated static func zoneSeconds(details: [String: Any], source: ZoneSource) -> [Double]? {
        let dict: [String: Any]?
        switch source {
        case .heartRate: dict = details["hr_zones_seconds"] as? [String: Any]
        case .power: dict = (details["cycling"] as? [String: Any])?["power_zones_seconds"] as? [String: Any]
        }
        guard let dict else { return nil }
        let zones = (1...5).map { Coerce.double(dict["z\($0)"]) ?? 0 }
        return zones.reduce(0, +) > 0 ? zones : nil
    }

    /// Element-wise sum of `z1…z5` across the records that carry the source's
    /// key; `[]` when none does.
    @MainActor
    static func aggregate(records: [WorkoutRecord], source: ZoneSource) -> [Double] {
        var total: [Double]? = nil
        for record in records {
            guard let data = record.detailsJSON.data(using: .utf8),
                  let details = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let zones = zoneSeconds(details: details, source: source)
            else { continue }
            total = zip(total ?? [0, 0, 0, 0, 0], zones).map(+)
        }
        return total ?? []
    }
}
