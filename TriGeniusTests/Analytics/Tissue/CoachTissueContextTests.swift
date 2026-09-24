import Testing
import Foundation
@testable import TriGenius

// Pins for what the coach is told about a group. The payload is the coach's only
// source for these numbers, so the shape and the keys are part of the contract.

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return c
}()

private let monday = cal.date(from: DateComponents(year: 2026, month: 9, day: 21))!

private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: monday)! }

/// `muscle`/`tendon` start `past` days before today.
private func forecast(_ group: TissueGroup, muscle: [Int], tendon: [Int]? = nil, past: Int = 0) -> TissueForecast {
    let days = muscle.indices.map { index in
        TissueDayState(date: day(index - past), muscle: LoadLevel(rawValue: muscle[index])!,
                       tendon: tendon.map { LoadLevel(rawValue: $0[index])! })
    }
    return TissueForecast(group: group, days: days, todayIndex: past)
}

private let calves = forecast(.calves, muscle: [2, 1, 1, 1], tendon: [4, 3, 2, 1])

private let thursdayRun = PlannedSession(id: UUID(), date: day(3), sport: .run,
                                         title: "3×3 km threshold", isKey: true,
                                         loads: [.calves], durationMinutes: 60)

private func context(forecasts: [TissueForecast] = [calves],
                     planned: [PlannedSession] = [thursdayRun],
                     drivers: [TissueDriver] = [],
                     sessionCount: Int = 180,
                     group: TissueGroup = .calves) -> CoachTissueContext? {
    let input = TissueCardModel.Input(forecasts: forecasts, conflicts: [], planned: planned,
                                      nextKeySession: planned.first, previouslyListed: [],
                                      period: .build1, sessionCount: sessionCount,
                                      drivers: drivers, today: monday)
    return CoachTissueContext.make(group: group, input: input, calendar: cal)
}

private func encoded(_ payload: CoachTissueContext) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(data: (try? encoder.encode(payload)) ?? Data(), encoding: .utf8) ?? ""
}

@Test func namesTheTendonThatGovernsTheForecast() {
    #expect(context()?.governingTissueLabel == "Achilles")
}

@Test func clearDayIsReportedAsACalendarDay() {
    // Achilles 4,3,2,1 → clear on Thursday.
    #expect(context()?.clearOn == "2026-09-24")
}

@Test func levelsStartThisMorningNotAtThePastDays() {
    // Two past days (3, 3) before today's 2: the coach reads today onward only.
    let withPast = forecast(.calves, muscle: [3, 3, 2, 1, 1, 1], tendon: [4, 4, 4, 3, 2, 1], past: 2)
    #expect(context(forecasts: [withPast])?.muscleLevels == [2, 1, 1, 1])
    #expect(context(forecasts: [withPast])?.clearOn == "2026-09-24")
}

@Test func plannedSessionCarriesItsOwnMorningLevel() {
    // Thursday's morning is the day the Achilles reaches Light — level 1, not today's 4.
    #expect(context()?.plannedAffecting.first?.morningLevel == 1)
}

@Test func driversAreTheSessionsThatLoadedThisGroup() {
    let longRun = TissueDriver(date: day(-1), sport: .run, title: "Long run 24 km", loads: [.calves])
    let swim = TissueDriver(date: day(-2), sport: .swim, title: "Technique", loads: [.shoulders])
    #expect(context(drivers: [longRun, swim])?.drivers.map(\.title) == ["Long run 24 km"])
}

@Test func confidenceDropsWhileTheHistoryIsStillThin() {
    #expect(context(sessionCount: 9)?.confidence == .moderate)
}

@Test func keysAreSnakeCaseLikeEveryOtherCoachPayload() {
    #expect(encoded(context()!).contains("\"governing_tissue\""))
}
