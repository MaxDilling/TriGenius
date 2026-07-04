import Foundation
import Testing
@testable import TriGenius

// Golden-master pins for the weekly-ring logic: cross-training credit
// (`applyCrossTrainingCredit`) and ring visibility (`visibleFamilies`). Expected
// credits are hand-computed from the formula. Update alongside
// Analytics/WeeklyTarget.swift.

private func target(_ tss: Double) -> WeeklyTarget {
    WeeklyTarget(durationMinutes: 0, tss: tss)
}

/// Apply credit to a fresh projection dict and return the resulting `creditedTSS`
/// per discipline. `actuals` seeds each discipline's `actualTSS` (= `projectedTSS`,
/// so the projected pass mirrors the actual pass unless a test overrides it).
private func actualCredits(
    targets: [SportFamily: WeeklyTarget],
    actuals: [SportFamily: Double],
    factor: Double
) -> [SportFamily: Double] {
    var proj: [SportFamily: WeeklyProjection] = [:]
    for (f, v) in actuals { proj[f] = WeeklyProjection(actualTSS: v, projectedTSS: v) }
    WeeklyTargets.applyCrossTrainingCredit(targets: targets, into: &proj, factor: factor)
    return SportFamily.triathlon.reduce(into: [:]) { $0[$1] = proj[$1]?.creditedTSS ?? 0 }
}

// MARK: - Cross-training credit

@Test func credit_featuresExample_halfFactor() {
    // 200 swim / 400 bike targets; ride 1000 bike (600 surplus), 0 swim.
    // pool = 0.5 × 600 = 300; swim deficit 200 → credited 200 (100 pool unused).
    let c = actualCredits(targets: [.swim: target(200), .bike: target(400)],
                          actuals: [.swim: 0, .bike: 1000], factor: 0.5)
    #expect(c[.swim] == 200)
    #expect(c[.bike] == 0)
}

@Test func credit_quarterFactor() {
    // pool = 0.25 × 600 = 150; swim deficit 200 → credited 150.
    let c = actualCredits(targets: [.swim: target(200), .bike: target(400)],
                          actuals: [.swim: 0, .bike: 1000], factor: 0.25)
    #expect(c[.swim] == 150)
}

@Test func credit_fullFactorCapsAtDeficit() {
    // pool = 1.0 × 600 = 600, but swim's credit can't exceed its 200 deficit.
    let c = actualCredits(targets: [.swim: target(200), .bike: target(400)],
                          actuals: [.swim: 0, .bike: 1000], factor: 1.0)
    #expect(c[.swim] == 200)
}

@Test func credit_twoDeficitsSplitProportionally() {
    // 200 swim / 400 bike / 300 run targets; bike surplus 600, pool 300.
    // deficits swim 200 + run 300 = 500 → swim 300×200/500 = 120, run 300×300/500 = 180.
    let c = actualCredits(targets: [.swim: target(200), .bike: target(400), .run: target(300)],
                          actuals: [.swim: 0, .bike: 1000, .run: 0], factor: 0.5)
    #expect(c[.swim] == 120)
    #expect(c[.run] == 180)
    #expect(c[.bike] == 0)
}

@Test func credit_zeroFactorNoCredit() {
    let c = actualCredits(targets: [.swim: target(200), .bike: target(400)],
                          actuals: [.swim: 0, .bike: 1000], factor: 0)
    #expect(c[.swim] == 0)
}

@Test func credit_noSurplusNoCredit() {
    // Everyone below target → no pool → no credit.
    let c = actualCredits(targets: [.swim: target(200), .bike: target(400)],
                          actuals: [.swim: 100, .bike: 200], factor: 0.5)
    #expect(c[.swim] == 0)
    #expect(c[.bike] == 0)
}

@Test func credit_creditsAMissingProjectionEntry() {
    // Swim has a target but no projection entry at all (never swam / planned) — it
    // must still receive credit from bike's surplus, creating the entry.
    var proj: [SportFamily: WeeklyProjection] = [.bike: WeeklyProjection(actualTSS: 1000, projectedTSS: 1000)]
    WeeklyTargets.applyCrossTrainingCredit(
        targets: [.swim: target(200), .bike: target(400)], into: &proj, factor: 0.5)
    #expect(proj[.swim]?.creditedTSS == 200)
}

@Test func credit_projectedPassUsesProjectedSurplus() {
    // Actual bike surplus 100 (pool 50), projected bike surplus 600 (pool 300):
    // swim's actual credit 50, projected credit 200 (capped at 200 deficit).
    var proj: [SportFamily: WeeklyProjection] = [
        .swim: WeeklyProjection(actualTSS: 0, projectedTSS: 0),
        .bike: WeeklyProjection(actualTSS: 500, projectedTSS: 1000)
    ]
    WeeklyTargets.applyCrossTrainingCredit(
        targets: [.swim: target(200), .bike: target(400)], into: &proj, factor: 0.5)
    #expect(proj[.swim]?.creditedTSS == 50)
    #expect(proj[.swim]?.projectedCreditTSS == 200)
}

// MARK: - Ring visibility

@Test func visible_defaultRatioShowsAllThree() {
    let v = WeeklyTargets.visibleFamilies(sportRatio: WeeklyStructure.defaultSportRatio)
    #expect(v == SportFamily.triathlon)
}

@Test func visible_zeroRatioHidesDiscipline() {
    let v = WeeklyTargets.visibleFamilies(sportRatio: [.swim: 0, .bike: 0.5, .run: 0.3])
    #expect(v == [.bike, .run])
}

@Test func visible_absentKeyHidesDiscipline() {
    let v = WeeklyTargets.visibleFamilies(sportRatio: [.bike: 0.6, .run: 0.4])
    #expect(v == [.bike, .run])
}
