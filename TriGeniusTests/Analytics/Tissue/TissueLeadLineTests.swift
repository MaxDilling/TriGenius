import Testing
import Foundation
@testable import TriGenius

// Pins for the card's headline: which template wins, and the exact sentence it renders.
// Locale is pinned to en_US so the weekday names are deterministic.

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return c
}()

private let english = Locale(identifier: "en_US")
private let monday = cal.date(from: DateComponents(year: 2026, month: 9, day: 21))!

private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: monday)! }

private func forecast(_ group: TissueGroup, muscle: Int, tendon: Int? = nil) -> TissueForecast {
    TissueForecast(group: group, days: [TissueDayState(date: monday,
                                                       muscle: LoadLevel(rawValue: muscle)!,
                                                       tendon: tendon.map { LoadLevel(rawValue: $0)! })])
}

private func session(_ offset: Int, _ sport: SportFamily, loads: Set<TissueGroup> = []) -> PlannedSession {
    PlannedSession(id: UUID(), date: day(offset), sport: sport, title: sport.displayName,
                   isKey: true, loads: loads, durationMinutes: 60)
}

private func lead(conflicts: [TissueConflict] = [], forecasts: [TissueForecast] = [],
                  listed: [TissueGroup] = [], period: ATPPeriod? = .build1,
                  nextKey: PlannedSession? = nil,
                  endurance: Bool = true, sessions: Int = 120) -> TissueLeadLine {
    TissueLeadLine.make(conflicts: conflicts, forecasts: forecasts, listed: listed, period: period,
                        nextKeySession: nextKey, hasEnduranceThisWeek: endurance,
                        sessionCount: sessions, calendar: cal, locale: english)
}

private let achillesConflict = TissueConflict(group: .calves, tissue: .tendon,
                                              session: session(1, .run, loads: [.calves]),
                                              morningLevel: .loaded)

@Test func conflict_namesTheDaySportAndTissue() {
    #expect(lead(conflicts: [achillesConflict]).text == "Tue run: Achilles load spike.")
}

@Test func conflict_outranksThinHistory() {
    // A conflict is actionable even when the estimates are still coarse.
    #expect(lead(conflicts: [achillesConflict], sessions: 9).glyph == .conflict)
}

@Test func thinHistory_reportsHowThin() {
    #expect(lead(sessions: 9).text == "Early estimates from 9 sessions.")
}

@Test func taper_namesTheRaceDay() {
    #expect(lead(period: .peak, nextKey: session(6, .run)).text == "Taper on track. Clear for Sunday.")
}

@Test func legsBlocked_offersTheUpperBodyWhenItIsClear() {
    let forecasts = [forecast(.calves, muscle: 3), forecast(.upperBack, muscle: 1)]
    #expect(lead(forecasts: forecasts, listed: [.calves]).text == "Legs today: no. Upper body: yes.")
}

@Test func strengthOnlyWeek_whenNoEnduranceIsPlanned() {
    let forecasts = [forecast(.calves, muscle: 1), forecast(.upperBack, muscle: 2)]
    #expect(lead(forecasts: forecasts, endurance: false).text == "Strength-only week. Legs are clear.")
}

@Test func buildWeek_isTheFallbackWhenTheRowsMixBlockedAndClear() {
    // An upper-body row among the listed ones means "legs today: no" would overstate it.
    let forecasts = [forecast(.calves, muscle: 3), forecast(.upperBack, muscle: 3)]
    #expect(lead(forecasts: forecasts, listed: [.calves, .upperBack]).text == "Build week, on plan.")
}

@Test func baseWeek_usesItsOwnWord() {
    let forecasts = [forecast(.calves, muscle: 3), forecast(.upperBack, muscle: 3)]
    #expect(lead(forecasts: forecasts, listed: [.calves, .upperBack], period: .base2).text == "Base week, on plan.")
}
