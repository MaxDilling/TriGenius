import Foundation
import Testing
@testable import TriGenius

// Golden-master pins for the ATP engine. Update alongside Analytics/ATPEngine.swift
// (+ ATPConstants.swift shape constants).

private let cal = Calendar.current
private func monday() -> Date { TrainingVolume.weekStart(of: Date(timeIntervalSince1970: 1_700_000_000)) }
private func weeks(_ from: Date, _ n: Int) -> Date { cal.date(byAdding: .weekOfYear, value: n, to: from)! }

private func params(_ start: Date, ctl: Double? = nil, method: ATPMethodology = .weeklyTSS, avg: Double = 0) -> ATPParams {
    ATPParams(startDate: start, startingCTL: ctl, methodology: method,
              recoveryCycle: 4, maxRampRate: 7, weeklyAverageTSS: avg)
}
private func event(_ date: Date, _ prio: ATPEventPriority, ctl: Double? = nil) -> ATPEventInput {
    ATPEventInput(id: UUID().uuidString, name: "E", date: date, eventType: "tri",
                  priority: prio, targetCTL: ctl, notes: "")
}

@Test func estimateStartingCTL_perSportPerHour() {
    // Appendix A: CTL per weekly hour — triathlete 8, cyclist 7, runner 9.
    #expect(ATPEngine.estimateStartingCTL(weeklyHours: 10, sport: "triathlete") == 80)
    #expect(ATPEngine.estimateStartingCTL(weeklyHours: 10, sport: "cyclist") == 70)
    #expect(ATPEngine.estimateStartingCTL(weeklyHours: 5, sport: "runner") == 45)
}

@Test func build_nilWithoutAnchorEvent() {
    let s = monday()
    #expect(ATPEngine.build(params: params(s, ctl: 40, method: .weeklyTSS, avg: 600),
                            events: [], overrides: [], history: []) == nil)
}

@Test func weeklyTSS_respectsPinAndStaysNonNegative() {
    let s = monday()
    let shells = ATPPeriodization.layout(params: params(s, avg: 600), events: [event(weeks(s, 10), .a)])
    let result = ATPEngine.weeklyTSS(
        shells: shells,
        params: params(s, ctl: 40, method: .weeklyTSS, avg: 600),
        overrides: [ATPWeekOverrideInput(weekStart: s, pinnedTSS: 0, note: "Urlaub")])
    #expect(result[0].plannedTSS == 0)
    #expect(result[0].pinned)
    #expect(result.allSatisfy { $0.plannedTSS >= 0 })
    // Pinning week 0 to 0 pushes its budget onto the free weeks: their mean clears
    // the weekly average.
    let free = result.dropFirst()
    #expect(free.reduce(0) { $0 + $1.plannedTSS } / Double(free.count) > 600)
}

@Test func targetCTL_planCurveHitsTarget() {
    let s = monday()
    let ev = weeks(s, 12)
    let plan = try! #require(ATPEngine.build(
        params: params(s, ctl: 40, method: .targetCTL),
        events: [event(ev, .a, ctl: 55)], overrides: [], history: []))
    // The plan-CTL curve should reach the target by the end of the event week.
    let weekEnd = cal.date(byAdding: .day, value: 6, to: TrainingVolume.weekStart(of: ev))!
    let pt = try! #require(plan.planCurve.last(where: { $0.date <= weekEnd }))
    #expect(abs(pt.ctl - 55) < 2)
}
