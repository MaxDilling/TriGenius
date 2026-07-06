import Foundation
import Testing
@testable import TriGenius

// Golden-master pins for the TrainingPeaks EWMA model. Expected values are the
// closed-form CTL/ATL (42-day / 7-day time constants) for the given daily TSS.
// Update alongside Analytics/PMCEngine.swift.

private let cal = Calendar.current
private let today = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

private func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: today)! }

@Test func emptyHistory_hasNoPoints() {
    let r = PMCEngine.compute(dailyTSS: [], today: today)
    #expect(r.points.isEmpty)
    #expect(r.snapshot == nil)
}

@Test func firstDay_appliesOneEWMAStep() {
    // Single 100-TSS day from zero: CTL = 100·(1−e^(−1/42)) ≈ 2.353,
    // ATL = 100·(1−e^(−1/7)) ≈ 13.312, TSB (yesterday's) = 0.
    let r = PMCEngine.compute(dailyTSS: [DailyTSS(date: today, totalTSS: 100)], today: today)
    let s = try! #require(r.snapshot)
    #expect(abs(s.ctl - 2.353) < 0.01)
    #expect(abs(s.atl - 13.312) < 0.01)
    #expect(s.tsb == 0)
}

@Test func steadyLoad_convergesToConstant() {
    // 100 TSS/day for long enough that both EWMAs settle: CTL ≈ ATL ≈ 100, TSB ≈ 0.
    let history = (0..<400).map { DailyTSS(date: daysAgo($0), totalTSS: 100) }
    let s = try! #require(PMCEngine.compute(dailyTSS: history, today: today).snapshot)
    #expect(abs(s.ctl - 100) < 0.5)
    #expect(abs(s.atl - 100) < 0.5)
    #expect(abs(s.tsb) < 0.5)
}

@Test func bigSingleDay_drivesFormNegative() {
    // Fatigue (fast EWMA) outruns fitness after a hard day → next-day TSB < 0.
    let history = [DailyTSS(date: daysAgo(1), totalTSS: 0), DailyTSS(date: today, totalTSS: 200)]
    let s = try! #require(PMCEngine.compute(dailyTSS: history, today: today).snapshot)
    #expect(s.atl > s.ctl)
}

@Test func project_continuesFromPlannedFutureTSS() {
    let history = PMCEngine.compute(dailyTSS: [DailyTSS(date: today, totalTSS: 100)], today: today).points
    let forecast = PMCEngine.project(
        history: history,
        plannedByDay: [cal.date(byAdding: .day, value: 1, to: today)!: 80],
        today: today
    )
    #expect(forecast.count == 1)
    #expect(forecast.first?.date == cal.date(byAdding: .day, value: 1, to: today))
}

@Test func project_emptyWhenNothingPlannedAhead() {
    let history = PMCEngine.compute(dailyTSS: [DailyTSS(date: today, totalTSS: 100)], today: today).points
    #expect(PMCEngine.project(history: history, plannedByDay: [:], today: today).isEmpty)
}

@Test func simulate_seedsThenDecaysWithZeroTSS() {
    // Seed CTL 100 at the anchor, then one zero-TSS day: CTL = 100·e^(−1/42) ≈ 97.647.
    let r = PMCEngine.simulate(anchorDate: today, ctl0: 100, dailyTSS: [:],
                               through: cal.date(byAdding: .day, value: 1, to: today)!)
    #expect(r.count == 2)
    #expect(r.first?.ctl == 100)
    #expect(abs(r.last!.ctl - 97.647) < 0.01)
}

@Test func decay_matchesEmptySimulate() {
    let end = cal.date(byAdding: .day, value: 10, to: today)!
    let a = PMCEngine.decay(fromDate: today, ctl0: 80, through: end)
    let b = PMCEngine.simulate(anchorDate: today, ctl0: 80, dailyTSS: [:], through: end)
    #expect(a.count == b.count)
    #expect(a.last!.ctl == b.last!.ctl)
}
