import Testing
import Foundation
@testable import TriGenius

// Golden-master pins for the Tissue Load rules over hand-set forecasts: Monday 21 Sep
// 2026 after a Sunday long run — the Achilles is heavy and clears Wed–Thu, muscle is
// light by Tuesday. Expected values are hand-derived from the rules in
// Analytics/Tissue/TissueLogic.swift; update them in the same change as the rules.
// The model that produces forecasts and conflicts is pinned in TissueLoadModelTests.

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return c
}()

private let monday = cal.date(from: DateComponents(year: 2026, month: 9, day: 21))!

private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: monday)! }

/// `muscle`/`tendon` start `past` days before today.
private func forecast(_ group: TissueGroup, muscle: [Int], tendon: [Int]? = nil, past: Int = 0) -> TissueForecast {
    let days = muscle.indices.map { i in
        TissueDayState(date: day(i - past), muscle: LoadLevel(rawValue: muscle[i])!,
                       tendon: tendon.map { LoadLevel(rawValue: $0[i])! })
    }
    return TissueForecast(group: group, days: days, todayIndex: past)
}

private func session(_ offset: Int, _ sport: SportFamily, key: Bool,
                     loads: Set<TissueGroup>, minutes: Int = 60) -> PlannedSession {
    PlannedSession(id: UUID(), date: day(offset), sport: sport, title: sport.displayName,
                   isKey: key, loads: loads, durationMinutes: minutes)
}

private let calves = forecast(.calves, muscle: [2, 1, 1, 1, 2, 1, 1], tendon: [4, 3, 2, 1, 3, 2, 2])
private let hamstrings = forecast(.hamstrings, muscle: [2, 1, 1, 1, 2, 1, 1], tendon: [1, 1, 0, 0, 1, 0, 0])
private let quads = forecast(.quads, muscle: [2, 1, 1, 2, 1, 1, 2], tendon: [1, 0, 0, 1, 0, 0, 1])
private let upperBack = forecast(.upperBack, muscle: [1, 1, 1, 1, 1, 1, 1])

// MARK: Governing tissue

@Test func governingTissue_tendonWinsWhenItIsTheWorseOne() {
    // Monday: muscle Moderate, Achilles Heavy → the tendon sets the forecast.
    #expect(calves.days[0].governing == .tendon)
}

@Test func governingTissue_muscleWinsWhenTheTendonIsLight() {
    // A tendon below Moderate never governs, even against Moderate muscle.
    #expect(hamstrings.days[0].governing == .muscle)
}

// MARK: Clear forecast

@Test func clearDay_isTheFirstMorningTheGoverningTissueIsLight() {
    // Achilles 4,3,2,1 → clear on Thu (offset 3).
    #expect(TissueLogic.clearDay(calves) == 3)
}

@Test func clearDay_clearsOnTheFirstLightDay() {
    #expect(TissueLogic.clearDay(hamstrings) == 1)
}

@Test func clearDay_clearToday() {
    #expect(TissueLogic.clearDay(upperBack) == 0)
}

@Test func clearDay_returnsNilWhenItNeverClearsInTheWindow() {
    #expect(TissueLogic.clearDay(forecast(.quads, muscle: [4, 4, 4])) == nil)
}

@Test func clearDay_countsFromTodayNotFromThePastDays() {
    // Clear two days ago, loaded today and tomorrow, clear Wed.
    #expect(TissueLogic.clearDay(forecast(.quads, muscle: [0, 1, 3, 3, 1], past: 2)) == 2)
}

// MARK: Card rows

@Test func cardRows_conflictFirstThenLatestClearDate() {
    let tueRun = session(1, .run, key: true, loads: [.calves])
    let found = [TissueConflict(group: .calves, tissue: .tendon, session: tueRun, morningLevel: .loaded)]
    // Hamstrings and quads both clear Tue → the tie falls back to anatomical order.
    let rows = TissueLogic.cardRows(forecasts: [upperBack, quads, hamstrings, calves],
                                    conflicts: found, nextKeySession: nil, previouslyListed: [])
    #expect(rows == [.calves, .hamstrings, .quads])
}

@Test func cardRows_taperFillsFromTheNextKeySession() {
    // Everything clear: the rows become what Sunday's race will load, all reading "Now".
    let clear = [forecast(.calves, muscle: [1, 0, 1, 0, 0, 0, 0], tendon: [1, 1, 1, 0, 1, 0, 0]),
                 forecast(.quads, muscle: [1, 0, 0, 1, 0, 0, 0]),
                 forecast(.hamstrings, muscle: [1, 1, 0, 0, 1, 0, 0])]
    let race = session(6, .run, key: true, loads: [.calves, .quads, .hamstrings])
    let rows = TissueLogic.cardRows(forecasts: clear, conflicts: [], nextKeySession: race, previouslyListed: [])
    #expect(rows == [.calves, .hamstrings, .quads])
}

@Test func cardRows_keepYesterdaysRowUntilItClears() {
    // Quads rank below calves on load alone, but stability keeps them at the top.
    let rows = TissueLogic.cardRows(forecasts: [calves, hamstrings, quads], conflicts: [],
                                    nextKeySession: nil, previouslyListed: [.quads])
    #expect(rows.first == .quads)
}

@Test func freeGroups_excludeTheListedOnes() {
    let free = TissueLogic.freeGroups(forecasts: [calves, hamstrings, upperBack],
                                      listed: [.calves, .hamstrings])
    #expect(free == [.upperBack])
}

// MARK: Chronic status

@Test func chronicStatus_underTargetForMostWeeks() {
    let weeks = [-2, -2, -1, -2, -2, -1].enumerated().map {
        ChronicWeek(weekStart: day(-7 * (6 - $0.offset)), deviation: $0.element)
    }
    #expect(TissueLogic.chronicStatus(weeks) == .under(weeks: 6))
}

@Test func chronicStatus_overTargetForMostWeeks() {
    let weeks = [0, 1, 1, 1, 2, 1].map { ChronicWeek(weekStart: monday, deviation: $0) }
    #expect(TissueLogic.chronicStatus(weeks) == .over(weeks: 5))
}

@Test func chronicStatus_onTargetWhenNeitherSideDominates() {
    let weeks = [0, 0, 1, 0, 0, 1].map { ChronicWeek(weekStart: monday, deviation: $0) }
    #expect(TissueLogic.chronicStatus(weeks) == .onTarget)
}

// MARK: Chronic rows

private func weeks(_ deviations: [Int]) -> [ChronicWeek] {
    deviations.enumerated().map { ChronicWeek(weekStart: day(-7 * (6 - $0.offset)), deviation: $0.element) }
}

@Test func chronicRows_mostWeeksOffTargetFirst() {
    let history: [TissueGroup: [ChronicWeek]] = [
        .glutes: weeks([-2, -2, -1, -2, -2, -1]),
        .calves: weeks([0, 1, 1, 1, 2, 1]),
        .quads: weeks([0, 0, 1, 0, 0, 1])
    ]
    // Glutes 6 weeks under, calves 5 over; quads stay inside the band and drop out.
    #expect(TissueLogic.chronicRows(history) == [.glutes, .calves])
}

@Test func chronicRows_tiesFallBackToAnatomicalOrder() {
    let history: [TissueGroup: [ChronicWeek]] = [
        .shoulders: weeks([-1, -1, -1, -1, 0, 0]),
        .hamstrings: weeks([-1, -1, -1, -1, 0, 0])
    ]
    #expect(TissueLogic.chronicRows(history) == [.hamstrings, .shoulders])
}
