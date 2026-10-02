import Testing
@testable import TriGenius

// Pins `Analytics/PlannedTSS.swift` where a strength plan meets the endurance
// estimators: its rest steps are pauses in an exercise list, never a timed extent.

private let strengthWithRest: [[String: Any]] = [
    ["type": "exercise", "exercise_id": "back_squat", "sets": [["reps": 10] as [String: Any]]],
    ["type": "rest", "end_condition": "time", "duration_seconds": 120],
]

@Test func aStrengthPlansRestStepCarriesNoTSS() {
    #expect(PlannedTSS.estimate(compactSteps: strengthWithRest, family: .strength, thresholds: PerformanceSnapshot()) == nil)
}

@Test func aStrengthPlansRestStepCarriesNoDuration() {
    #expect(PlannedTSS.totalDurationSeconds(compactSteps: strengthWithRest, family: .strength,
                                            thresholds: PerformanceSnapshot()) == nil)
}

// A swim's timed rest is spent at the wall: it adds time, never metres or load.
// 200 + 6 × 50 + 5 × 100 + 150 = 1150 m; at the unmeasured-CSS typical of
// 2:00 / 100 m that is 1380 s swum at IF 0.90 → 0.81 × 1380 / 36 = 31.05 TSS,
// plus 11 × 20 s of rest = 1600 s elapsed.

private func swimRepeat(_ count: Int, meters: Double) -> [String: Any] {
    ["repeat_count": count, "repeat_steps": [
        ["type": "interval", "distance_meters": meters],
        ["type": "rest", "duration_seconds": 20],
    ] as [[String: Any]]]
}

private let swimWithWallRests: [[String: Any]] = [
    ["type": "warmup", "distance_meters": 200],
    swimRepeat(6, meters: 50),
    swimRepeat(5, meters: 100),
    ["type": "cooldown", "distance_meters": 150],
]

@Test func aSwimsWallRestCoversNoDistance() {
    let distance = PlannedTSS.totalDistance(compactSteps: swimWithWallRests, family: .swim, thresholds: PerformanceSnapshot())
    #expect(distance?.meters == 1150 && distance?.source == .fixed)
}

@Test func aSwimsWallRestCarriesNoTSS() {
    #expect(PlannedTSS.estimate(compactSteps: swimWithWallRests, family: .swim, thresholds: PerformanceSnapshot()) == 31)
}

@Test func aSwimsWallRestStillCountsAsDuration() {
    #expect(PlannedTSS.totalDurationSeconds(compactSteps: swimWithWallRests, family: .swim,
                                            thresholds: PerformanceSnapshot()) == 1600)
}

@Test func aRunsTimedRecoveryStillCoversDistance() {
    let steps: [[String: Any]] = [["type": "recovery", "duration_seconds": 360]]
    #expect(PlannedTSS.totalDistance(compactSteps: steps, family: .run, thresholds: PerformanceSnapshot())?.meters == 1000)
}
