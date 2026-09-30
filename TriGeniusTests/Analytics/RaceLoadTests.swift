import Foundation
import Testing
@testable import TriGenius

// Golden-master pins for `Analytics/RaceLoad.swift`. Curve and single-leg values are
// hand-computed from the formula (TSS = IF² × h × 100); the effort-driven cases are
// the formula's fixed point, iterated off-line exactly as `RaceLoad.legs` does
// (4 rounds). Thresholds: run 4:30/km, CSS 1:40/100 m. Update alongside
// Analytics/RaceLoad.swift and the race constants in TSSConstants.

private let thresholds: PerformanceSnapshot = {
    var t = PerformanceSnapshot()
    t.lactateThrPaceSeconds = 270
    t.cssPaceSeconds = 100
    return t
}()

private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

// MARK: - Race IF curve

@Test func raceIF_isOneAtTheOneHourAnchor() {
    #expect(close(RaceLoad.intensity(hours: 1, effort: .race), 1.00))
}

@Test func raceIF_interpolatesInLogTime() {
    // 1.00 − 0.07 × ln(1.5)/ln(2)
    #expect(close(RaceLoad.intensity(hours: 1.5, effort: .race), 0.959052624949519))
}

@Test func raceIF_isFlatBelowTheFirstAnchor() {
    #expect(close(RaceLoad.intensity(hours: 0.1, effort: .race), 1.08))
}

@Test func raceIF_isFlatBeyondTheLastAnchor() {
    #expect(close(RaceLoad.intensity(hours: 20, effort: .race), 0.68))
}

@Test func raceIF_easyEffortScalesTheCurve() {
    // 0.80 × 0.93
    #expect(close(RaceLoad.intensity(hours: 2, effort: .easy), 0.744))
}

// MARK: - Legs

@Test func goalTime_setsTheRunIFAgainstThreshold() {
    // 21097.5 m in 105 min = 3.3488 m/s vs 3.7037 m/s threshold → IF 0.904179;
    // 0.904179² × 1.75 h × 100
    let leg = RaceLoad.legs([RaceLeg(sport: .run, distanceMeters: 21_097.5, goalMinutes: 105)],
                            effort: .race, thresholds: thresholds)[0]
    #expect(close(leg.tss, 143.06930558035717))
}

@Test func goalTime_isNotAnEstimatedIF() {
    let leg = RaceLoad.legs([RaceLeg(sport: .run, distanceMeters: 21_097.5, goalMinutes: 105)],
                            effort: .race, thresholds: thresholds)[0]
    #expect(!leg.isEstimated)
}

@Test func ownIF_onABikeLegRunsAtTheFlatSpeed() {
    // 40 km at 28 km/h = 1.428571 h; 0.8² × 1.428571 × 100
    let leg = RaceLoad.legs([RaceLeg(sport: .bike, distanceMeters: 40_000, intensityFactor: 0.8)],
                            effort: .race, thresholds: thresholds)[0]
    #expect(close(leg.tss, 91.42857142857144))
}

@Test func halfMarathonAllOut_settlesOnTheCurve() {
    let leg = RaceLoad.legs([RaceLeg(sport: .run, distanceMeters: 21_097.5)],
                            effort: .race, thresholds: thresholds)[0]
    #expect(close(leg.tss, 150.05112462640113))
}

@Test func halfMarathonEasy_isSlowerAndLighter() {
    let leg = RaceLoad.legs([RaceLeg(sport: .run, distanceMeters: 21_097.5)],
                            effort: .easy, thresholds: thresholds)[0]
    #expect(close(leg.tss, 116.55278351804598))
}

@Test func olympicTriathlon_pacesEveryLegForTheWholeRace() {
    let legs = RaceLoad.legs(ATPEventType.triOlympic.defaultLegs, effort: .race, thresholds: thresholds)
    #expect(close(legs.reduce(0) { $0 + $1.tss }, 216.65291174604832))
}

@Test func legWithoutDistanceOrGoal_carriesNoLoad() {
    let leg = RaceLoad.legs([RaceLeg(sport: .run)], effort: .race, thresholds: thresholds)[0]
    #expect(leg.tss == 0)
}
