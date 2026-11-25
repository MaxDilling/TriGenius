import Testing
@testable import TriGenius

// Pins `Analytics/StrengthProgression.swift`: an auto-load exercise's weight
// from its last two sessions — reps against the target, the sets' ratings, and
// the size of the miss.

private func prescribed(_ id: String, reps: [Int], kg: [Double?], auto: Bool = true) -> [String: Any] {
    var step: [String: Any] = ["type": "exercise", "exercise_id": id,
                               "sets": zip(reps, kg).map { reps, kg in
                                   var set: [String: Any] = ["reps": reps]
                                   if let kg { set["weight_kg"] = kg }
                                   return set
                               }]
    if auto { step["load"] = "auto" }
    return step
}

private func lifted(_ reps: [Int?], at kg: Double, rated effort: StrengthSets.Effort? = nil,
                    rpe: Int? = nil) -> StrengthProgression.Session {
    .init(sets: reps.map { StrengthSets.SetRow(reps: $0, weightKg: kg, effort: effort) }, rpe: rpe)
}

/// The planned weights after progressing, given the sessions latest first.
private func weights(_ step: [String: Any], _ sessions: StrengthProgression.Session...) -> [Double?] {
    StrengthSets.plannedSets(StrengthProgression.progressing([step]) { _ in sessions }).map(\.weightKg)
}

private let squat8 = prescribed("back_squat", reps: [8, 8, 8], kg: [60, 60, 60])
private let squat10 = prescribed("back_squat", reps: [10, 10, 10], kg: [60, 60, 60])
private let legPress = prescribed("leg_press", reps: [10, 10, 10], kg: [140, 140, 140])

@Test func repsAroundTheTargetKeepTheWeight() {
    #expect(weights(squat8, lifted([8, 8, 9], at: 60)) == [60, 60, 60])
}

@Test func twoRepsOverTheTargetStepUp() {
    // e1RM 60 × (1 + 11.5/30) = 83 → for 8 reps 63.0 → 62.5.
    #expect(weights(squat8, lifted([10, 10, 10], at: 60)) == [62.5, 62.5, 62.5])
}

@Test func theTargetRatedEasyStepsUp() {
    #expect(weights(squat8, lifted([8, 8, 8], at: 60, rated: .easy)) == [62.5, 62.5, 62.5])
}

@Test func twoShortRatedHardStillFits() {
    #expect(weights(squat10, lifted([8, 8, 8], at: 60, rated: .hard)) == [60, 60, 60])
}

@Test func threeShortRatedEasyStillFits() {
    #expect(weights(squat10, lifted([7, 7, 7], at: 60, rated: .easy)) == [60, 60, 60])
}

@Test func threeShortStepsDownToTheEstimate() {
    // e1RM 60 × (1 + 8.5/30) = 77 → for 10 reps 55.7 → 55.
    #expect(weights(squat10, lifted([7, 7, 7], at: 60)) == [55, 55, 55])
}

@Test func aHeavyMachineMovesByTheLargerPlate() {
    // 7.5 % of 140 = 10.5 → the 10 kg step; e1RM 203 → for 10 reps 146.8 → 150.
    #expect(weights(legPress, lifted([12, 12, 12], at: 140)) == [150, 150, 150])
}

@Test func farOffMovesAfterOneSessionAndByTheEstimate() {
    // e1RM 140 × (1 + 16.5/30) = 217 → for 10 reps 156.9 → 160, past one step.
    #expect(weights(legPress, lifted([15, 15, 15], at: 140), lifted([10, 10, 10], at: 140)) == [160, 160, 160])
}

@Test func twoSessionsLeaningApartHoldTheWeight() {
    #expect(weights(squat8, lifted([10, 10, 10], at: 60), lifted([8, 8, 8], at: 60)) == [60, 60, 60])
}

@Test func twoSessionsLeaningTheSameWayStepUp() {
    #expect(weights(squat8, lifted([10, 10, 10], at: 60), lifted([10, 10, 10], at: 60)) == [62.5, 62.5, 62.5])
}

@Test func theWeightFollowsWhatWasLiftedLastTime() {
    #expect(weights(squat8, lifted([8, 8, 8], at: 62.5)) == [62.5, 62.5, 62.5])
}

@Test func anUncountedSetLeansNowhere() {
    #expect(weights(squat8, lifted([10, nil, 8], at: 60)) == [60, 60, 60])
}

@Test func fewerSetsThanPrescribedAreNeverTooLight() {
    #expect(weights(squat8, lifted([10, 10], at: 60)) == [60, 60, 60])
}

@Test func aHardSessionHoldsAnIncreaseBack() {
    #expect(weights(squat8, lifted([10, 10, 10], at: 60, rpe: 9)) == [60, 60, 60])
}

@Test func aFixedExerciseKeepsItsWeight() {
    #expect(weights(prescribed("back_squat", reps: [8], kg: [60], auto: false), lifted([12], at: 60)) == [60])
}

@Test func aCustomExerciseKeepsItsWeight() {
    let custom: [String: Any] = ["type": "exercise", "exercise_name": "Sled push", "load": "auto",
                                 "sets": [["reps": 8, "weight_kg": 60]]]
    #expect(weights(custom, lifted([12], at: 60)) == [60])
}

@Test func anAutoExerciseWithoutAWeightTakesTheLastOne() {
    #expect(weights(prescribed("goblet_squat", reps: [10, 10], kg: [nil, nil]), lifted([10, 10], at: 20)) == [20, 20])
}

@Test func aPyramidMovesAsAWhole() {
    // Top set 70 kg: e1RM 96.8 → for 8 reps 73.5 → 75 on the 5 kg step.
    #expect(weights(prescribed("back_squat", reps: [8, 6], kg: [60, 70]), lifted([10, 8], at: 70)) == [65, 75])
}

@Test func aCircuitMemberMovesEveryRound() {
    let circuit: [String: Any] = ["type": "repeat", "repeat_count": 2,
                                  "repeat_steps": [prescribed("goblet_squat", reps: [10], kg: [20])]]
    #expect(weights(circuit, lifted([12, 12], at: 20)) == [22, 22])
}
