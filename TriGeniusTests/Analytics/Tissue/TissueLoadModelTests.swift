import Testing
import Foundation
@testable import TriGenius

// Pins `Analytics/Tissue/TissueLoadModel.swift`. The history is a daily run of
// TL 50 up to the day before yesterday, which settles every morning state at its
// steady value long before the 28-day baseline window:
//   muscle (τ 1 d): 50·e⁻¹/(1−e⁻¹) = 29.1        tendon (τ 3 d): 50·e^−⅓/(1−e^−⅓) = 126.4
// so each group's own average is exactly that steady state (calves: weight 1.0/1.0).
// Scenario ratios are chosen well clear of the level boundaries (½, 1, 1½, 2).

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return c
}()

private let monday = cal.date(from: DateComponents(year: 2026, month: 9, day: 21))!

private func run(_ offset: Int, tl: Double, planned: Bool = false) -> TissueSession {
    TissueSession(date: cal.date(byAdding: .day, value: offset, to: monday)!, sport: .run, title: "Run",
                  durationMinutes: 60, isPlanned: planned, dose: TissueSession.endurance(.run, tl: tl))
}

/// Daily TL 50 runs from 60 days ago through `lastDay`.
private func dailyRuns(through lastDay: Int = -2, from firstDay: Int = -60) -> [TissueSession] {
    (firstDay...lastDay).map { run($0, tl: 50) }
}

private func model(_ sessions: [TissueSession]) -> TissueLoadModel.Output {
    TissueLoadModel.run(sessions, today: monday, past: 2, ahead: 7, calendar: cal)
}

private func calves(_ output: TissueLoadModel.Output) -> TissueForecast? {
    output.forecasts.first { $0.group == .calves }
}

// MARK: Dose

@Test func aRunDosesEachGroupByTheSportsWeight() {
    let dose = TissueSession.endurance(.run, tl: 100)
    #expect(dose[.calves] == TissueDose(muscle: 100, tendon: 100))
    #expect(dose[.quads] == TissueDose(muscle: 80, tendon: 60))
    #expect(dose[.shins] == TissueDose(muscle: 50))
    #expect(dose[.shoulders] == nil)
}

@Test func aStrengthSetDosesPrimaryFullSecondaryHalfAndTendonWhereLoaded() {
    // Back squat (Garmin: quads + glutes, hamstrings secondary), loads a tendon; 3 sets × 8.
    let dose = TissueSession.strength(Array(repeating: StrengthSets.SetRow(exerciseId: "back_squat", reps: 5), count: 3))
    #expect(dose[.quads] == TissueDose(muscle: 24, tendon: 24))
    #expect(dose[.glutes] == TissueDose(muscle: 24, tendon: 0))
    #expect(dose[.hamstrings] == TissueDose(muscle: 12, tendon: 0))
}

@Test func aRecordedExerciseOutsideTheLibraryStillGetsGarminsGroups() {
    let lunge = StrengthSets.SetRow(exerciseName: "DUMBBELL_LUNGE", exerciseCategory: "LUNGE", reps: 10)
    #expect(Set(TissueSession.strength([lunge]).keys) == [.quads, .glutes, .hamstrings])
}

@Test func everyGarminMuscleFoldsOntoAGroup() {
    // Push-up (Garmin: chest; abs, shoulders, triceps secondary) — chest → Shoulders, abs → Low back.
    let dose = TissueSession.strength([StrengthSets.SetRow(exerciseId: "push_up", reps: 10)])
    #expect(dose == [.shoulders: TissueDose(muscle: 8), .lowBack: TissueDose(muscle: 4), .triceps: TissueDose(muscle: 4)])
}

@Test func aGroupAnySetWorksAsPrimaryMoverIsPrimary() {
    // Push-up: shoulders; low back, triceps secondary. Triceps pushdown (Garmin: triceps).
    let targets = TissueSession.targets([StrengthSets.SetRow(exerciseId: "push_up", reps: 10),
                                         StrengthSets.SetRow(exerciseId: "triceps_pushdown", reps: 12),
                                         StrengthSets.SetRow(exerciseName: "Custom", reps: 5)])
    #expect(targets == [.shoulders: .primary, .triceps: .primary, .lowBack: .secondary])
}

// MARK: Levels

@Test func aRestDayClearsTheMuscleBeforeTheTendon() {
    // Morning after a rest day: muscle 29.1·e⁻¹ = 10.7 (0.37× → Fresh),
    // tendon 126.4·e^−⅓ = 90.5 (0.72× → Light).
    let today = calves(model(dailyRuns()))?.today
    #expect(today?.muscle == .fresh)
    #expect(today?.tendon == .light)
}

@Test func aBigDayReadsHeavyAgainstTheAthletesOwnAverage() {
    // Yesterday TL 150 instead of 50: muscle (29.1 + 150)·e⁻¹ = 65.9 (2.26× → Heavy),
    // tendon (126.4 + 150)·e^−⅓ = 198.0 (1.57× → Loaded).
    let today = calves(model(dailyRuns() + [run(-1, tl: 150)]))?.today
    #expect(today?.muscle == .heavy)
    #expect(today?.tendon == .loaded)
}

@Test func aDaysOwnSessionShowsOnThatDayNotOnlyTheNext() {
    // Tomorrow's morning: 29.1·e⁻¹ = 10.7 (0.37× → Fresh). After its planned TL 200 run:
    // 10.7 + 200 = 210.7 against the average after-training state 29.1 + 50 = 79.1
    // (2.66× → Heavy) — the cell for that day carries the run.
    let forecast = calves(model(dailyRuns(through: -1) + [run(1, tl: 200, planned: true)]))
    #expect(forecast?.days[3].muscle == .fresh)
    #expect(forecast?.afterTraining[3].muscle == .heavy)
}

@Test func theForecastCarriesThePastDaysBeforeToday() {
    let forecast = calves(model(dailyRuns()))
    #expect(forecast?.days.count == 9)
    #expect(forecast?.todayIndex == 2)
    #expect(forecast?.days.first?.date == cal.date(byAdding: .day, value: -2, to: monday))
}

@Test func aGroupWithNoLoadAtAllIsAbsent() {
    #expect(!model(dailyRuns()).forecasts.contains { $0.group == .shoulders })
}

@Test func aPlanLeftOpenInThePastCarriesNoLoad() {
    #expect(model(dailyRuns() + [run(-1, tl: 150, planned: true)]).forecasts
            == model(dailyRuns()).forecasts)
}

// MARK: Spike conflicts

@Test func aRunTheTissueIsUsedToIsNoConflict() {
    // Post-run state stays at the 30-day peak (steady + 50), never 10 % above it.
    #expect(model(dailyRuns(through: -1) + [run(1, tl: 50, planned: true)]).conflicts.isEmpty)
}

@Test func aRunThreeTimesTheUsualSpikesTheAchilles() {
    // Tendon after it: 126.4·e^−⅓ + 150 = 240.5 against the peak 126.4 + 50 = 176.4 (> 1.1×).
    let conflicts = model(dailyRuns(through: -1) + [run(1, tl: 150, planned: true)]).conflicts
    #expect(conflicts.first { $0.group == .calves }?.tissue == .tendon)
}

@Test func noSpikeWarningBeforeFourWeeksOfHistory() {
    #expect(model(dailyRuns(through: -1, from: -20) + [run(1, tl: 150, planned: true)]).conflicts.isEmpty)
}

// MARK: Plan

@Test func theHeaviestPlannedSessionIsKey() {
    let planned = model(dailyRuns() + [run(1, tl: 40, planned: true), run(3, tl: 90, planned: true)]).planned
    #expect(planned.map(\.isKey) == [false, true])
}

// MARK: Chronic

@Test func chronicWaitsForSixFullWeeks() {
    #expect(model(dailyRuns(from: -20)).chronic == nil)
}

@Test func steadyWeeksSitOnTheirOwnAverage() {
    let weeks = model(dailyRuns(through: -1)).chronic?[.calves]
    #expect(weeks?.map(\.deviation) == [0, 0, 0, 0, 0, 0])
}
