import Foundation
import Testing
@testable import TriGenius

// Pins `Analytics/StrengthSession.swift`: how a plan unrolls into the units a live
// session works through, where each rest lands, and how logging, rests, holds,
// pauses and reordering move the session on.

private let t0 = Date(timeIntervalSinceReferenceDate: 0)

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func exercise(_ id: String, reps: [Int], rest: Double = 60, weight: Double? = nil) -> [String: Any] {
    ["type": "exercise", "exercise_id": id, "rest_after": "none",
     "sets": reps.map { r -> [String: Any] in
         var set: [String: Any] = ["reps": r, "rest_seconds": rest]
         if let weight { set["weight_kg"] = weight }
         return set
     }]
}

private func session(_ steps: [[String: Any]]) -> StrengthSession {
    StrengthSession(planId: "local:1", planName: "Gym", sport: "strength", plannedMinutes: 30, steps: steps, at: t0)
}

private func done(_ s: inout StrengthSession, at time: TimeInterval, reps: Int? = nil) {
    var set = s.draft!
    if let reps { set.reps = reps }
    s.complete(set, at: at(time))
}

@Test func aCircuitUnrollsRoundByRoundWithItsRoundRestBetweenRounds() {
    let circuit: [String: Any] = ["type": "repeat", "repeat_count": 2, "rest_between_rounds_seconds": 90,
                                  "repeat_steps": [exercise("push_up", reps: [12]), exercise("russian_twist", reps: [20])]]
    let units = StrengthSession.units(planned: [circuit])
    #expect(units[0].sets.map(\.rest) == [nil, .timed(seconds: 90), nil, nil])
}

@Test func aRestStepBecomesTheRestAfterTheSetBeforeIt() {
    let rest: [String: Any] = ["type": "rest", "end_condition": "time", "duration_seconds": 120]
    let units = StrengthSession.units(planned: [exercise("back_squat", reps: [5, 5]), rest, exercise("push_up", reps: [10])])
    #expect(units.map { $0.sets.map(\.rest) } == [[.timed(seconds: 60), .timed(seconds: 120)], [nil]])
}

@Test func loggingASetStartsItsTimedRest() {
    var s = session([exercise("back_squat", reps: [5, 5])])
    done(&s, at: 40)
    #expect(s.phase == .resting(since: at(40), until: at(100)))
}

@Test func aRestThatRanOutReadsAsTheNextSetAndIsLoggedAtItsLength() {
    var s = session([exercise("back_squat", reps: [5, 5])])
    done(&s, at: 40)
    s.settle(at: at(500))
    #expect(s.phase == .working(since: at(100)) && s.log[0].set.restSeconds == 60)
}

@Test func skippingARestLogsTheRestActuallyTaken() {
    var s = session([exercise("back_squat", reps: [5, 5])])
    done(&s, at: 40)
    s.skipRest(at: at(65))
    #expect(s.log[0].set.restSeconds == 25)
}

@Test func aRestCannotBeShortenedIntoThePast() {
    var s = session([exercise("back_squat", reps: [5, 5])])
    done(&s, at: 40)
    s.adjustRest(by: -60, at: at(70))
    #expect(s.phase == .resting(since: at(40), until: at(70)))
}

@Test func aPauseShiftsTheRestAndIsLeftOutOfTheElapsedTime() {
    var s = session([exercise("back_squat", reps: [5, 5])])
    done(&s, at: 40)
    s.pause(at: at(50))
    s.resume(at: at(170))
    #expect(s.phase == .resting(since: at(160), until: at(220)) && s.elapsed(at: at(200)) == 80)
}

@Test func aPausedRestDoesNotRunOut() {
    var s = session([exercise("back_squat", reps: [5, 5])])
    done(&s, at: 40)
    s.pause(at: at(50))
    #expect(s.phase(at: at(500)) == .resting(since: at(40), until: at(100)))
}

@Test func theLastSetEndsTheSession() {
    var s = session([exercise("back_squat", reps: [5])])
    done(&s, at: 40)
    #expect(s.endedAt == at(40))
}

@Test func anEditedSetIsLoggedAsEditedAndTheNextOneStartsFromThePrescription() {
    var s = session([exercise("back_squat", reps: [5, 5])])
    var set = s.draft!
    set.reps = 3
    s.edit(set)
    s.complete(s.draft!, at: at(40))
    #expect(s.performed.map(\.reps) == [3] && s.draft?.reps == 5)
}

@Test func theDraftCarriesTheWeightLastLoggedForTheExercise() {
    var s = session([exercise("back_squat", reps: [5, 5], weight: 60)])
    var first = s.draft!
    first.weightKg = 62.5
    s.complete(first, at: at(40))
    #expect(s.draft?.weightKg == 62.5)
}

@Test func theLoggedSetKeepsWhatWasDoneNotThePrescription() {
    var s = session([exercise("back_squat", reps: [5, 5])])
    done(&s, at: 40, reps: 4)
    #expect(s.performed.map(\.reps) == [4])
}

@Test func aHoldLogsTheSecondsHeld() {
    var s = session([["type": "exercise", "exercise_id": "plank", "sets": [["duration_seconds": 30]]]])
    s.startHold(at: at(10))
    var set = s.draft!
    set.seconds = 20
    s.complete(set, at: at(30))
    #expect(s.performed.map(\.seconds) == [20])
}

@Test func theCurrentSetCountsWithinItsExercise() {
    var s = session([exercise("back_squat", reps: [5, 5, 5])])
    done(&s, at: 40)
    s.skipRest(at: at(50))
    #expect(s.currentSetPosition! == (2, 3))
}

@Test func doNowPutsAUnitBeforeTheCurrentOneWhichKeepsItsProgress() {
    var s = session([exercise("back_squat", reps: [5, 5]), exercise("push_up", reps: [10]), exercise("plank_row", reps: [8])])
    done(&s, at: 40)
    s.doNow(unit: 2)
    #expect(s.units.map { "\($0.id):\($0.done)" } == ["2:0", "0:1", "1:0"])
}

@Test func stationTakenMovesTheCurrentUnitBehindEverythingStillToDo() {
    var s = session([exercise("back_squat", reps: [5]), exercise("push_up", reps: [10]), exercise("plank_row", reps: [8])])
    s.moveCurrentToEnd()
    #expect(s.units.map(\.id) == [1, 2, 0])
}

@Test func reorderingMovesOnlyTheUpcomingUnits() {
    var s = session([exercise("back_squat", reps: [5]), exercise("push_up", reps: [10]),
                     exercise("plank_row", reps: [8]), exercise("lunge", reps: [8])])
    s.moveUpcoming(from: [2], to: 0)
    #expect(s.units.map(\.id) == [0, 3, 1, 2])
}

@Test func aSwapReplacesOnlyTheSetsStillToDoAndRemembersTheOriginal() {
    var s = session([exercise("single_leg_calf_raise", reps: [12, 12])])
    done(&s, at: 40)
    s.swap(unit: 0, replacing: s.current!, with: "calf_raise", name: "Calf raise", weightKg: nil)
    #expect(s.units[0].sets.map(\.exerciseId) == ["single_leg_calf_raise", "calf_raise"])
}

@Test func aSwapTakesTheGivenRepsAndWeightForEverySetStillToDo() {
    var s = session([exercise("back_squat", reps: [10, 8, 6], weight: 60)])
    done(&s, at: 40)
    s.swap(unit: 0, replacing: s.current!, with: "leg_press", name: "Leg press", reps: 12, weightKg: 100)
    #expect(s.units[0].sets.map { "\($0.reps!)@\($0.weightKg!)" } == ["10@60.0", "12@100.0", "12@100.0"])
}

@Test func swappingTwiceStillNamesTheExerciseThePlanHad() {
    var s = session([exercise("single_leg_calf_raise", reps: [12])])
    let original = s.current!.title
    s.swap(unit: 0, replacing: s.current!, with: "calf_raise", name: "Calf raise", weightKg: nil)
    s.swap(unit: 0, replacing: s.current!, with: "seated_calf_raise", name: "Seated calf raise", weightKg: nil)
    #expect(s.units[0].replaced == ["Seated calf raise": original])
}
