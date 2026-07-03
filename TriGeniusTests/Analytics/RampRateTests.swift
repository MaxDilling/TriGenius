import Foundation
import Testing
@testable import TriGenius

// Golden-master pins for the weekly CTL-delta series. Expected deltas are read
// straight off the synthetic CTL sequences. Update alongside Analytics/RampRate.swift.

private let cal = Calendar.current
private let today = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

private func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: today)! }

/// An ascending PMC series ending today, `days` long, with `ctl(dayIndex)` supplied.
private func series(days: Int, ctl: (Int) -> Double) -> [PMCPoint] {
    (0..<days).map { i in
        PMCPoint(date: daysAgo(days - 1 - i), ctl: ctl(i), atl: 0, tsb: 0)
    }
}

@Test func linearCTL_deltaIsSevenPerWeek() {
    // ctl rises 1/day over 6 weeks → every full week gains exactly 7.
    let points = series(days: 42) { Double($0) }
    let weeks = RampRate.weeklySeries(points: points, weeks: 4, today: today)
    #expect(weeks.count == 4)
    #expect(weeks.dropLast().allSatisfy { abs($0.delta - 7) < 1e-9 })
}

@Test func flatCTL_deltaIsZero() {
    let points = series(days: 42) { _ in 80 }
    let weeks = RampRate.weeklySeries(points: points, weeks: 4, today: today)
    #expect(weeks.count == 4)
    #expect(weeks.allSatisfy { $0.delta == 0 })
}

@Test func shortHistory_omitsUncoveredWeeks() {
    // 10 days of points can baseline at most the current and previous week.
    let points = series(days: 10) { Double($0) }
    let weeks = RampRate.weeklySeries(points: points, weeks: 4, today: today)
    #expect(weeks.count <= 2)
    #expect(!weeks.isEmpty)
}

@Test func partialCurrentWeek_usesLatestPoint() {
    let points = series(days: 42) { Double($0) }
    let last = RampRate.weeklySeries(points: points, weeks: 4, today: today).last!
    #expect(last.ctlEnd == 41)
}

@Test func safeBand_isFiveToEight() {
    #expect(RampRate.safeBand == 5.0...8.0)
}
