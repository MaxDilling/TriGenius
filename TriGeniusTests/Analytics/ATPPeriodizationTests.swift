import Foundation
import Testing
@testable import TriGenius

// Golden-master pins for the period layout. Update alongside
// Analytics/ATPPeriodization.swift (+ ATPConstants.swift period lengths).

private let cal = Calendar.current
private func monday() -> Date { TrainingVolume.weekStart(of: Date(timeIntervalSince1970: 1_700_000_000)) }
private func weeks(_ from: Date, _ n: Int) -> Date { cal.date(byAdding: .weekOfYear, value: n, to: from)! }

private func params(_ start: Date, recovery: Int = 4) -> ATPParams {
    ATPParams(startDate: start, startingCTL: 40, methodology: .weeklyTSS,
              recoveryCycle: recovery, maxRampRate: 7, weeklyAverageTSS: 600)
}
private func event(_ date: Date, _ prio: ATPEventPriority, ctl: Double? = nil) -> ATPEventInput {
    ATPEventInput(id: UUID().uuidString, name: "E", date: date, eventType: .triOlympic,
                  priority: prio, targetCTL: ctl, notes: "")
}

@Test func layout_emptyWithoutAnchorEvent() {
    let s = monday()
    #expect(ATPPeriodization.layout(params: params(s), events: []).isEmpty)
    // A C-priority event doesn't anchor periodization.
    #expect(ATPPeriodization.layout(params: params(s), events: [event(weeks(s, 5), .c)]).isEmpty)
}

@Test func layout_singleAEvent_ladderTaperRecoveryTail() {
    let s = monday()
    let ev = weeks(s, 10)
    let shells = ATPPeriodization.layout(params: params(s), events: [event(ev, .a)])

    #expect(shells.count == 12)                 // weeks 0…10 + one transition tail
    #expect(shells[10].period == .race)         // event week
    #expect(shells[9].period == .peak)
    #expect(shells[11].period == .transition)   // tail after the event

    #expect(shells[0].weeksToNextEvent == 10)
    #expect(shells[10].weeksToNextEvent == 0)

    // Taper = the 2 weeks ending at an A event (peak + race).
    #expect(shells[9].isTaper)
    #expect(shells[10].isTaper)
    #expect(!shells[8].isTaper)

    // Recovery cadence every 4th week, never on race/transition/taper weeks.
    #expect(shells[3].isRecovery)
    #expect(shells[7].isRecovery)
    #expect(!shells[10].isRecovery)
}

@Test func layout_recoveryCadenceFollowsCycle() {
    let s = monday()
    let shells = ATPPeriodization.layout(params: params(s, recovery: 3), events: [event(weeks(s, 10), .a)])
    // Every 3rd week now (i+1)%3==0 → indices 2, 5 (8 is peak-taper, excluded).
    #expect(shells[2].isRecovery)
    #expect(shells[5].isRecovery)
    #expect(!shells[3].isRecovery)
}
