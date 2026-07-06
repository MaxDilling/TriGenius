// CoachActivityProjection.swift
//
// Projects a stored activity's rich `detailsJSON` down to the lean, TSS-focused
// view the coach actually needs. Source-agnostic by construction: it reads the
// shared schema both Garmin and HealthKit write, so a field is dropped/kept the
// same way regardless of where the workout came from.
//
// `summary` is the default `get_workouts` payload — the whitelist below drops
// per-lap swim arrays, calorie/EPOC noise and computation-only keys, and injects
// `tss` + `tss_basis` (which live on `WorkoutRecord`, not in `detailsJSON`).
// `detail` adds the per-lap breakdown for a single requested workout.

import Foundation

nonisolated enum CoachActivityProjection {

    /// Top-level keys kept for every sport. `tss` / `tss_basis` are injected from
    /// the record (omitted when nil); `feel` / `rpe` / `notes` appear only when the
    /// athlete recorded them.
    private static let commonKeys = [
        "id", "name", "date", "time", "sport",
        "duration_minutes", "distance_km", "avg_hr", "max_hr",
        "elevation_gain_m", "hr_zones_seconds", "feel", "rpe", "notes",
    ]

    /// Per-sport keys kept — the TSS inputs plus the few metrics a coach reads at a
    /// glance. Everything else (max/best values, cadence noise, EPOC, calories,
    /// per-lap arrays, computation-only swim keys) is dropped.
    private static let sportKeys: [String: [String]] = [
        "running":  ["normalized_pace_s_per_km", "avg_pace_min_km", "avg_power_w", "avg_cadence_spm"],
        "cycling":  ["normalized_power_w", "avg_power_w", "avg_speed_kmh", "avg_cadence_rpm"],
        "swimming": ["pool_length_m", "total_lengths", "avg_pace_per_100m", "avg_swolf", "avg_strokes_per_length"],
    ]

    static func summary(_ details: [String: Any], tss: Double?, tssBasis: String?) -> [String: Any] {
        var out: [String: Any] = [:]
        pick(commonKeys, from: details, into: &out)
        if let tss { out["tss"] = tss }
        if let tssBasis { out["tss_basis"] = tssBasis }
        for (sport, keys) in sportKeys {
            guard let sub = details[sport] as? [String: Any] else { continue }
            var leanSub: [String: Any] = [:]
            pick(keys, from: sub, into: &leanSub)
            if !leanSub.isEmpty { out[sport] = leanSub }
        }
        return out
    }

    /// The summary plus the per-lap breakdown (swim `intervals`) for a single
    /// drilled-into workout.
    static func detail(_ details: [String: Any], tss: Double?, tssBasis: String?) -> [String: Any] {
        var out = summary(details, tss: tss, tssBasis: tssBasis)
        if let swim = details["swimming"] as? [String: Any],
           let intervals = swim["intervals"] as? [[String: Any]], !intervals.isEmpty {
            var sub = out["swimming"] as? [String: Any] ?? [:]
            sub["intervals"] = intervals
            out["swimming"] = sub
        }
        return out
    }

    private static func pick(_ keys: [String], from src: [String: Any], into dst: inout [String: Any]) {
        for key in keys {
            guard let value = src[key], !(value is NSNull) else { continue }
            dst[key] = value
        }
    }
}
