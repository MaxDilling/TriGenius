import Foundation
import Testing
@testable import TriGenius

// Pins `Analytics/PlanResolution.swift`: when a plan with automatic values is
// frozen, and what a target given as a share of a threshold stands for.

private var thresholds: PerformanceSnapshot {
    var snapshot = PerformanceSnapshot()
    snapshot.lactateThrPaceSeconds = 300
    snapshot.cssPaceSeconds = 100
    snapshot.cyclingFTP = 250
    snapshot.lactateThrHR = 170
    return snapshot
}

private func day(_ offset: Int, from now: Date) -> Date {
    Calendar.current.date(byAdding: .day, value: offset, to: now)!
}

@Test func aFasterPaceShareIsFewerSecondsPerKilometre() {
    // 300 s/km at 105 % speed → 285.7 → 286 s.
    #expect(PlanResolution.thresholdTarget(type: "pace", percent: 105, family: .run, thresholds: thresholds) == 286)
}

@Test func aSwimPaceShareReadsCSS() {
    #expect(PlanResolution.thresholdTarget(type: "pace", percent: 90, family: .swim, thresholds: thresholds) == 111)
}

@Test func aPowerShareReadsFTP() {
    #expect(PlanResolution.thresholdTarget(type: "power", percent: 75, family: .bike, thresholds: thresholds) == 188)
}

@Test func aHeartRateShareReadsLTHR() {
    #expect(PlanResolution.thresholdTarget(type: "heart_rate", percent: 85, family: .run, thresholds: thresholds) == 145)
}

@Test func anUnknownThresholdSetsNoTarget() {
    #expect(PlanResolution.thresholdTarget(type: "power", percent: 75, family: .bike, thresholds: PerformanceSnapshot()) == nil)
}

@Test func aPlanFreezesFourDaysBefore() {
    let now = Date.now
    #expect([4, 5].map { PlanResolution.isDue(day($0, from: now), now: now) } == [true, false])
}

@Test func aCircuitMemberOnAutoMakesThePlanRelative() {
    let circuit: [String: Any] = ["type": "repeat", "repeat_steps": [["type": "exercise", "load": "auto"]]]
    #expect(PlanResolution.isRelative([["type": "exercise"], circuit]))
}

@Test func freezingDropsEveryMarkerAndKeepsTheValues() {
    let steps: [[String: Any]] = [["type": "interval", "target_type": "pace", "target_percent": 105, "target_low": 266],
                                  ["type": "repeat", "repeat_steps": [["type": "exercise", "load": "auto"]]]]
    let frozen = PlanResolution.frozen(steps)
    #expect(!PlanResolution.isRelative(frozen) && Coerce.double(frozen[0]["target_low"]) == 266)
}
