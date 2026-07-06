import Testing
import Foundation
@testable import TriGenius

// Pins the lean coach-facing activity projection: the whitelist keeps the TSS
// inputs + glanceable metrics, injects tss/tss_basis, and drops the heavy swim
// per-lap arrays + noise. `detail` re-attaches the per-lap breakdown.

private let swim: [String: Any] = [
    "id": "g:1", "name": "Pool Swim", "date": "2026-06-20", "time": "07:00",
    "sport": "swimming", "duration_minutes": 30, "distance_km": 1.5,
    "avg_hr": 130, "max_hr": 150, "calories": 300, "location": "Hallenbad",
    "aerobic_te": 2.1, "training_load": 80,
    "swimming": [
        "pool_length_m": 25, "total_lengths": 60, "avg_pace_per_100m": "2:00",
        "avg_swolf": 38, "avg_strokes_per_length": 18,
        "garmin_distance_m": 1500, "cleaned_distance_m": 1500, "swim_time_s": 1700,
        "intervals": [["interval": 1, "distance_m": 100], ["interval": 2, "distance_m": 100]],
        "lengths": [["d": 30, "s": 18, "m": 25]],
    ],
]

@Test func summary_dropsNoiseAndSwimArrays() {
    let out = CoachActivityProjection.summary(swim, tss: 42, tssBasis: "swim pace vs CSS (cleaned distance)")
    #expect(out["tss"] as? Double == 42)
    #expect(out["tss_basis"] as? String == "swim pace vs CSS (cleaned distance)")
    #expect(out["calories"] == nil)
    #expect(out["location"] == nil)
    #expect(out["training_load"] == nil)
    let sub = out["swimming"] as? [String: Any]
    #expect(sub?["avg_pace_per_100m"] as? String == "2:00")
    #expect(sub?["intervals"] == nil)
    #expect(sub?["lengths"] == nil)
    #expect(sub?["garmin_distance_m"] == nil)
    #expect(sub?["swim_time_s"] == nil)
}

@Test func summary_omitsTSSWhenNil() {
    let out = CoachActivityProjection.summary(swim, tss: nil, tssBasis: nil)
    #expect(out["tss"] == nil)
    #expect(out["tss_basis"] == nil)
}

@Test func detail_reattachesIntervals() {
    let out = CoachActivityProjection.detail(swim, tss: 42, tssBasis: nil)
    let sub = out["swimming"] as? [String: Any]
    #expect((sub?["intervals"] as? [[String: Any]])?.count == 2)
    #expect(sub?["lengths"] == nil)   // compute-only, stays out even in detail
}

@Test func summary_runKeepsNormalizedPaceDropsBest() {
    let run: [String: Any] = [
        "id": "g:2", "sport": "running", "duration_minutes": 50, "distance_km": 10,
        "running": ["normalized_pace_s_per_km": 300, "avg_pace_min_km": "5:05",
                    "best_pace_min_km": "4:30", "avg_cadence_spm": 178, "steps": 9000],
    ]
    let out = CoachActivityProjection.summary(run, tss: 60, tssBasis: "normalized pace vs threshold pace")
    let sub = out["running"] as? [String: Any]
    #expect(sub?["normalized_pace_s_per_km"] as? Int == 300)
    #expect(sub?["best_pace_min_km"] == nil)
    #expect(sub?["steps"] == nil)
}
