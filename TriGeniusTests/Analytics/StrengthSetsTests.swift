import Testing
@testable import TriGenius

// Pins `Analytics/StrengthSets.swift`: a plan's structure as the set table shows
// it, and a recorded session paired set by set with its plan — which sets come
// back flagged (Tissue Load handoff D6), which prescribed sets were never done.

private func plannedExercise(_ id: String, reps: [Int], rest: Double = 90) -> [String: Any] {
    ["type": "exercise", "exercise_id": id,
     "sets": reps.map { ["reps": $0, "rest_seconds": rest] as [String: Any] }]
}

private func performedExercise(_ key: String, reps: [Int?]) -> [String: Any] {
    ["exercise_name": key, "exercise_category": "X",
     "sets": reps.map { r -> [String: Any] in r.map { ["reps": $0] } ?? [:] }]
}

private func compare(_ planned: [[String: Any]], _ performed: [[String: Any]]) -> [StrengthSets.Line] {
    StrengthSets.comparison(planned: planned, performed: StrengthSets.rows(performed: performed))
}

@Test func aPlannedExerciseRestsBetweenItsSetsOnly() {
    let blocks = StrengthSets.blocks(planned: [plannedExercise("back_squat", reps: [10, 10, 10])])
    #expect(blocks[0].items[0].lines.map { $0.set?.restSeconds } == [90, 90, nil])
}

@Test func aCircuitStaysOneBlockWithItsRoundsAndRoundRest() {
    let circuit: [String: Any] = ["type": "repeat", "repeat_count": 4, "rest_between_rounds_seconds": 60,
                                  "repeat_steps": [plannedExercise("push_up", reps: [12]),
                                                   plannedExercise("russian_twist", reps: [20])]]
    let blocks = StrengthSets.blocks(planned: [circuit])
    #expect(blocks.count == 1)
    #expect(blocks[0].rounds == 4)
    #expect(blocks[0].roundRestSeconds == 60)
    #expect(blocks[0].items.count == 2)
}

@Test func aRestStepBetweenExercisesIsItsOwnItemAndReplacesTheRestAfter() {
    let rest: [String: Any] = ["type": "rest", "end_condition": "time", "duration_seconds": 120]
    let blocks = StrengthSets.blocks(planned: [plannedExercise("back_squat", reps: [10]), rest,
                                              plannedExercise("push_up", reps: [10])])
    #expect(blocks.map { $0.items.count } == [1, 1, 2])
    #expect(blocks[1].items[0] == .rest(.timed(seconds: 120)))
}

@Test func anExerciseRestsUntilLapAfterItsLastSetUnlessToldOtherwise() {
    var timed = plannedExercise("push_up", reps: [10])
    timed["rest_after"] = "timed"
    timed["rest_after_seconds"] = 90
    var superset = plannedExercise("russian_twist", reps: [20])
    superset["rest_after"] = "none"
    let steps = [plannedExercise("back_squat", reps: [5]), timed, superset]
    #expect(steps.indices.map { StrengthSets.restAfter(steps, at: $0) } == [.lapButton, .timed(seconds: 90), nil])
}

@Test func circuitMembersFollowEachOtherDirectly() {
    let circuit: [String: Any] = ["type": "repeat", "repeat_count": 3,
                                  "repeat_steps": [plannedExercise("push_up", reps: [12]),
                                                   plannedExercise("russian_twist", reps: [20])]]
    #expect(StrengthSets.blocks(planned: [circuit])[0].items.allSatisfy { $0.lines.count == 1 })
}

@Test func aSetCanRestUntilLap() {
    let step: [String: Any] = ["type": "exercise", "exercise_id": "back_squat",
                               "sets": [["reps": 5, "rest_until_lap": true], ["reps": 5]]]
    #expect(StrengthSets.blocks(planned: [step])[0].items[0].lines.map { $0.set?.rest } == [.lapButton, nil])
}

@Test func recordedSetsRoundTripThroughTheirStoredEntries() {
    let stored = [performedExercise("PUSH_UP", reps: [10, 11]), performedExercise("RUSSIAN_TWIST", reps: [6])]
    let rows = StrengthSets.rows(performed: stored)
    #expect(StrengthSets.rows(performed: StrengthSets.entries(rows)) == rows)
    #expect(StrengthSets.entries(rows).count == 2)
}

@Test func aRatedSetKeepsItsEffortThroughItsStoredEntry() {
    var rows = StrengthSets.rows(performed: [performedExercise("PUSH_UP", reps: [10])])
    rows[0].effort = .hard
    #expect(StrengthSets.rows(performed: StrengthSets.entries(rows)).map(\.effort) == [.hard])
}

@Test func aRecordedGarminKeyReadsAsTheLibraryName() {
    let rows = StrengthSets.rows(performed: [performedExercise("PUSH_UP", reps: [10]),
                                             performedExercise("LEG_CURL", reps: [10])])
    #expect(rows.map(\.title) == ["Push-up", "Leg curl"])
}

@Test func aRecordedSetIsPairedWithItsPrescribedSet() {
    let lines = compare([plannedExercise("back_squat", reps: [8, 6])],
                        [performedExercise("BARBELL_BACK_SQUAT", reps: [8, 6])])
    #expect(lines.map { $0.plan?.reps } == [8, 6])
}

@Test func setsMatchingThePlanAreNotFlagged() {
    #expect(compare([plannedExercise("back_squat", reps: [10, 10, 10])],
                    [performedExercise("BARBELL_BACK_SQUAT", reps: [10, 10, 10])]).map(\.isFlagged)
            == [false, false, false])
}

@Test func aMiscountedAndAnUncountedSetAreFlagged() {
    #expect(compare([plannedExercise("back_squat", reps: [10, 10, 10])],
                    [performedExercise("BARBELL_BACK_SQUAT", reps: [10, 8, nil])]).map(\.isFlagged)
            == [false, true, true])
}

@Test func anExtraSetBeyondThePlanIsNotADiscrepancy() {
    let lines = compare([plannedExercise("back_squat", reps: [10, 10])],
                        [performedExercise("BARBELL_BACK_SQUAT", reps: [10, 10, 10])])
    #expect(lines.map(\.isFlagged) == [false, false, false])
    #expect(lines[2].plan == nil)
}

@Test func anImprovisedExerciseIsNeverFlagged() {
    let lines = compare([], [performedExercise("PUSH_UP", reps: [12, nil])])
    #expect(lines.map(\.isFlagged) == [false, false])
}

@Test func aSkippedSetFollowsTheLastRecordedSetOfItsExercise() {
    let lines = compare([plannedExercise("back_squat", reps: [10, 10, 10]), plannedExercise("push_up", reps: [12])],
                        [performedExercise("BARBELL_BACK_SQUAT", reps: [10, 10]), performedExercise("PUSH_UP", reps: [12])])
    #expect(lines.map { $0.set?.reps } == [10, 10, nil, 12])
    #expect(lines[2].plan?.reps == 10)
    #expect(lines[2].isFlagged == false)
}

@Test func aSkippedExerciseComesLast() {
    let lines = compare([plannedExercise("back_squat", reps: [10]), plannedExercise("push_up", reps: [12])],
                        [performedExercise("PUSH_UP", reps: [12])])
    #expect(lines.map(\.title) == ["Push-up", "Back squat"])
    #expect(lines[1].set == nil)
}

@Test func aCircuitsInterleavedRoundsLineUpWithThePlan() {
    let circuit: [String: Any] = ["type": "repeat", "repeat_count": 2,
                                  "repeat_steps": [plannedExercise("push_up", reps: [12]),
                                                   plannedExercise("russian_twist", reps: [20])]]
    #expect(compare([circuit], [performedExercise("PUSH_UP", reps: [12]), performedExercise("RUSSIAN_TWIST", reps: [20]),
                                performedExercise("PUSH_UP", reps: [9]), performedExercise("RUSSIAN_TWIST", reps: [20])])
                .map(\.isFlagged)
            == [false, false, true, false])
}

@Test func theCoachReadsARecordedSessionOneLinePerExercise() {
    let stored: [[String: Any]] = [
        ["exercise_name": "BARBELL_BACK_SQUAT", "exercise_category": "SQUAT",
         "sets": [["reps": 5, "weight_kg": 60.0], ["reps": 4, "weight_kg": 62.5]]],
        ["exercise_name": "PUSH_UP", "exercise_category": "PUSH_UP", "sets": [["reps": 12]]],
        ["exercise_name": "PLANK", "exercise_category": "PLANK", "sets": [["duration_seconds": 45.2]]],
    ]
    #expect(StrengthSets.coachLines(performed: stored)
            == ["back_squat: 5×60kg, 4×62.5kg", "push_up: 12", "plank: 45s"])
}
