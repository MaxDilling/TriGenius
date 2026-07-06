import Testing
@testable import TriGenius

// Golden-master pins for the single completed-activity TSS computation. Inputs are
// the normalized `detailsJSON` schema TSSCalculator reads; expected values are the
// hand-computed IF²·h·100 (rounded) for each dispatch path. Update these in the
// same change as the formula in Analytics/TSSCalculator.swift.

private func snapshot(ftp: Int? = nil, runThrPace: Double? = nil, css: Double? = nil) -> PerformanceSnapshot {
    PerformanceSnapshot(cyclingFTP: ftp, runningFTP: nil, cssPaceSeconds: css,
                        lactateThrHR: nil, maxHR: nil, lactateThrPaceSeconds: runThrPace,
                        vo2maxRunning: nil, vo2maxCycling: nil, weightKg: nil)
}

@Test func powerTSS_normalizedPowerVsFTP() {
    // IF = 200/250 = 0.8 → 0.8²·1h·100 = 64.
    let d: [String: Any] = ["sport": "cycling", "duration_minutes": 60,
                            "cycling": ["normalized_power_w": 200]]
    let r = TSSCalculator.compute(details: d, snapshot: snapshot(ftp: 250))
    #expect(r.tss == 64)
    #expect(r.basis == .power)
}

@Test func runPaceTSS_normalizedPaceVsThreshold() {
    // IF = threshold(240) / pace(300) = 0.8 → 64.
    let d: [String: Any] = ["sport": "running", "duration_minutes": 60,
                            "running": ["normalized_pace_s_per_km": 300]]
    let r = TSSCalculator.compute(details: d, snapshot: snapshot(runThrPace: 240))
    #expect(r.tss == 64)
    #expect(r.basis == .runPace)
}

@Test func swimPaceTSS_beatsTheDurationFloor() {
    // pace = 3600s / (3000m/100) = 120 s/100m; IF = css(90)/120 = 0.75 → 56.25 → 56,
    // above the 0.63²·100 ≈ 40 floor, so the CSS pace drives it.
    let d: [String: Any] = ["sport": "lap_swimming", "duration_minutes": 60,
                            "distance_km": 3.0, "swimming": ["swim_time_s": 3600]]
    let r = TSSCalculator.compute(details: d, snapshot: snapshot(css: 90))
    #expect(r.tss == 56)
    #expect(r.basis == .swimPace)
}

@Test func swimFallsToDurationFloor_withoutCSS() {
    // No CSS → duration floor only: 0.63²·1h·100 ≈ 39.69 → 40.
    let d: [String: Any] = ["sport": "lap_swimming", "duration_minutes": 60,
                            "swimming": ["swim_time_s": 3600]]
    let r = TSSCalculator.compute(details: d, snapshot: snapshot())
    #expect(r.tss == 40)
    #expect(r.basis == .swimDuration)
}

@Test func hrZoneLoad_isTheFallbackWhenNoPowerOrPace() {
    // Z3 for 1h: 0.89²·100·0.77 ≈ 60.99 → 61. Strength has no power/pace path.
    let d: [String: Any] = ["sport": "strength", "duration_minutes": 60,
                            "hr_zones_seconds": ["z3": 3600]]
    let r = TSSCalculator.compute(details: d, snapshot: snapshot())
    #expect(r.tss == 61)
    #expect(r.basis == .hrZones)
}

@Test func noUsableInputs_yieldsNil() {
    let d: [String: Any] = ["sport": "other", "duration_minutes": 60]
    #expect(TSSCalculator.tss(details: d, snapshot: snapshot()) == nil)
}

@Test func zeroDuration_yieldsNil() {
    let d: [String: Any] = ["sport": "cycling", "duration_minutes": 0,
                            "cycling": ["normalized_power_w": 200]]
    #expect(TSSCalculator.tss(details: d, snapshot: snapshot(ftp: 250)) == nil)
}
