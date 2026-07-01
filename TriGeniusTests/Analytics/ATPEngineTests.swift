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
    ATPEventInput(id: UUID().uuidString, name: "E", date: date, eventType: .triOlympic,
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

@Test func weeklyTSS_flagsRampExceeded() {
    let s = monday()
    let shells = ATPPeriodization.layout(params: params(s, avg: 600), events: [event(weeks(s, 10), .a)])
    // A tiny ceiling → ramping weeks trip the flag; a huge one → none do.
    let strict = ATPParams(startDate: s, startingCTL: 40, methodology: .weeklyTSS,
                           recoveryCycle: 4, maxRampRate: 0.5, weeklyAverageTSS: 600)
    #expect(ATPEngine.weeklyTSS(shells: shells, params: strict, overrides: []).contains { $0.rampExceeded })
    let loose = ATPParams(startDate: s, startingCTL: 40, methodology: .weeklyTSS,
                          recoveryCycle: 4, maxRampRate: 1000, weeklyAverageTSS: 600)
    #expect(ATPEngine.weeklyTSS(shells: shells, params: loose, overrides: []).allSatisfy { !$0.rampExceeded })
}

@Test func targetCTL_lowerEventNeverReducesTraining() {
    let s = monday()
    let aWeek = weeks(s, 16), bWeek = weeks(s, 8)
    // Same shells for both so we compare only the TSS solve.
    let shells = ATPPeriodization.layout(params: params(s), events: [event(bWeek, .b), event(aWeek, .a)])
    let p = params(s, ctl: 40, method: .targetCTL)
    let high = ATPEngine.targetCTL(shells: shells, params: p, events: [event(aWeek, .a, ctl: 90)], overrides: [])
    // A low-CTL event placed before the A must not pull any week down.
    let both = ATPEngine.targetCTL(shells: shells, params: p,
                                   events: [event(bWeek, .b, ctl: 30), event(aWeek, .a, ctl: 90)], overrides: [])
    for (a, b) in zip(high, both) { #expect(b.plannedTSS >= a.plannedTSS - 0.5) }
}

@Test func targetCTL_progressiveLoadWithRecoveryDips() {
    let s = monday()
    let ev = weeks(s, 30)   // far event: room for a gentle progressive climb
    let shells = ATPPeriodization.layout(params: params(s), events: [event(ev, .a)])
    let p = params(s, ctl: 30, method: .targetCTL)
    let result = ATPEngine.targetCTL(shells: shells, params: p, events: [event(ev, .a, ctl: 90)], overrides: [])
    // Recovery week is a real dip below the load week before it in its block.
    if let ri = result.firstIndex(where: { $0.isRecovery && $0.plannedTSS > 0 }), ri > 0 {
        #expect(result[ri].plannedTSS < result[ri - 1].plannedTSS)
    }
    // Progressive overload: a late build load week outweighs the first base load week.
    let loads = result.filter { $0.period.isBaseOrBuild && !$0.isRecovery && !$0.isTaper }
    #expect(loads.count >= 2)
    #expect(loads.last!.plannedTSS > loads.first!.plannedTSS)
}

@Test func targetCTL_pinnedRestWeekStillReachesTarget() {
    let s = monday()
    let ev = weeks(s, 16)
    let restWeek = weeks(s, 4)
    let plan = try! #require(ATPEngine.build(
        params: params(s, ctl: 40, method: .targetCTL),
        events: [event(ev, .a, ctl: 70)],
        overrides: [ATPWeekOverrideInput(weekStart: restWeek, pinnedTSS: 0, note: "Urlaub")], history: []))
    // Pin honoured verbatim, and the free weeks re-solve around it so the target is still
    // hit — the P1 regression (a pin used to make the target unreachable).
    #expect(plan.weeks.first { $0.weekStart == restWeek }!.plannedTSS == 0)
    let weekEnd = cal.date(byAdding: .day, value: 6, to: TrainingVolume.weekStart(of: ev))!
    let pt = try! #require(plan.planCurve.last(where: { $0.date <= weekEnd }))
    #expect(abs(pt.ctl - 70) < 3)
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
