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
