import Foundation
import Testing
@testable import TriGenius

// Pins `LTPaceEstimate`. The band, the p75 aggregation, the 0.799 fraction and the
// flat carry-forward are the spec — see `ref/ltpace_lab/FINDINGS.md` for how each was
// measured. Expected values are hand-computed from the formulas.
struct LTPaceEstimateTests {

    private let hrMax = 206.0, hrRest = 48.0   // reserve 158 bpm

    /// 1 Hz `(value, seconds)` samples, as the sources shape them for zone bucketing.
    private func flat(_ value: Double, minutes: Int) -> [NormalizedStream.Sample] {
        (0..<(minutes * 60)).map { _ in (value: value, seconds: 1.0) }
    }

    private func day(_ ago: Int) -> Date { Date().addingTimeInterval(-Double(ago) * 86_400) }

    private func runs(_ speeds: [Double], count: Int,
                      everyDays: Int = 5) -> [(date: Date, speeds: [Double])] {
        (0..<count).map { (date: day($0 * everyDays), speeds: speeds) }
    }

    // MARK: profile

    @Test func warmUpIsExcludedFromTheProfile() {
        // 16 min: the first 10 are the HR-lag skip, leaving exactly the six blocks
        // the run has to hold.
        let p = LTPaceEstimate.profile(gradeAdjustedSpeed: flat(3.0, minutes: 16),
                                       heartRate: flat(170, minutes: 16))
        #expect(p == [170: 3.0])
    }

    @Test func aRunTooShortToHoldSixSettledBlocksYieldsNothing() {
        // One minute under the gate. A run this short is decided by whichever two or
        // three minutes happened to be quickest, which is not a statement about MAS.
        #expect(LTPaceEstimate.profile(gradeAdjustedSpeed: flat(3.0, minutes: 15),
                                       heartRate: flat(170, minutes: 15)).isEmpty)
    }

    @Test func onlyTheFastestBlockPerHeartRateIsKept() {
        var speed = flat(3.0, minutes: 16)
        for i in 900..<960 { speed[i] = (value: 3.5, seconds: 1.0) }   // the 16th minute
        let p = LTPaceEstimate.profile(gradeAdjustedSpeed: speed, heartRate: flat(170, minutes: 16))
        #expect(p == [170: 3.5])
    }

    @Test func aBlockContainingAStopIsDropped() {
        var speed = flat(3.0, minutes: 16)
        for i in 600..<605 { speed[i] = (value: 0, seconds: 1.0) }     // 5 s stopped > 5 %
        var hr = flat(170, minutes: 16)
        for i in 660..<960 { hr[i] = (value: 150, seconds: 1.0) }      // the five that survive
        #expect(LTPaceEstimate.profile(gradeAdjustedSpeed: speed, heartRate: hr) == [150: 3.0])
    }

    @Test func aStopKeepsConsumingTimeSoTheStreamsStayPaired() {
        // Zero-speed seconds must not be dropped: the HR stream would slide forward
        // and the block would be paired with the wrong heart rate.
        var speed = flat(3.0, minutes: 16)
        for i in 0..<60 { speed[i] = (value: 0, seconds: 1.0) }        // stopped in the warm-up
        var hr = flat(170, minutes: 16)
        for i in 900..<960 { hr[i] = (value: 150, seconds: 1.0) }
        let p = LTPaceEstimate.profile(gradeAdjustedSpeed: speed, heartRate: hr)
        #expect(p == [170: 3.0, 150: 3.0])
    }

    // MARK: maxAerobicSpeed

    @Test func masScalesSpeedByTheUnusedHeartRateReserve() {
        // 3.2 * 158 / (170 - 48)
        let speeds = LTPaceEstimate.aerobicSpeeds(profile: [170: 3.2], hrMax: hrMax, hrRest: hrRest)
        #expect(abs(speeds[0] - 4.144262295081967) < 1e-12)
    }

    @Test func everyInBandBucketContributes() {
        // Not just the run's best: pooling every bucket is what keeps one session
        // from deciding the answer.
        let speeds = LTPaceEstimate.aerobicSpeeds(profile: [170: 3.2, 180: 3.3],
                                                  hrMax: hrMax, hrRest: hrRest).sorted()
        #expect(speeds.count == 2)
    }

    @Test func bucketsOutsideTheBandDoNotCount() {
        // Band is 164.8 - 195.7 bpm at HRmax 206; an easy 150 bpm bucket is excluded
        // however fast it was, and 200 bpm is above the ceiling.
        #expect(LTPaceEstimate.aerobicSpeeds(profile: [150: 4.5, 200: 5.0],
                                             hrMax: hrMax, hrRest: hrRest).isEmpty)
    }

    @Test func missingRestingHeartRateYieldsNoEstimate() {
        #expect(LTPaceEstimate.aerobicSpeeds(profile: [170: 3.2],
                                             hrMax: hrMax, hrRest: 0).isEmpty)
    }

    // MARK: estimate

    /// The athlete's own fraction, as `snapshot(asOf:)` derives it from LTHR. Pinned
    /// rather than referenced so a change to the constant shows up here as a failure.
    private let fraction = 0.8   // 0.828 %HRR at threshold / 1.035 pool inflation

    @Test func aFullWindowResolvesToTheQuantileOfTheReconstructions() {
        // Seven runs of one identical best: the quantile is that value, and the LT speed
        // is 0.8 of it (3.2 m/s = 312.5 s/km), snapped to the 1 s/km grid -> 313.
        let est = LTPaceEstimate.estimate(runs: runs([4.0], count: 7), asOf: Date())!
        #expect(est.masMps == 4.0)
        #expect(est.confidence == .anchored)
        #expect(abs(1000 / LTPaceEstimate.ltSpeed(mas: est.masMps, fractionOfMAS: fraction)! - 313) < 1e-9)
    }

    /// The p75 index is `0.75 x (n - 1)`, so a short window points the "quantile" at one
    /// or two sessions. It still answers — that is the best evidence there is — but it
    /// must not be reported as though a full window stood behind it.
    @Test func aWindowBelowSevenRunsAnswersAsThin() {
        for count in 3 ... 6 {
            #expect(LTPaceEstimate.estimate(runs: runs([4.0], count: count),
                                            asOf: Date())?.confidence == .thin)
        }
    }

    @Test func fewerThanTheGateYieldsNothing() {
        #expect(LTPaceEstimate.estimate(runs: runs([4.0], count: 2), asOf: Date()) == nil)
    }

    @Test func oneSessionCannotCarryAWindowHoweverManyBucketsItHolds() {
        let single = [(date: day(1), speeds: Array(repeating: 4.0, count: 50))]
        #expect(LTPaceEstimate.estimate(runs: single, asOf: Date()) == nil)
    }

    @Test func eachRunContributesOnlyItsBest() {
        // One run holding a fast bucket cannot outvote the rest by bucket count: the
        // quantile runs across sessions, so six runs at 4.0 and one at 9.0 give
        // q0.75 of {4,4,4,4,9} = 4.0 -> 313, not something pulled up by the outlier.
        let skewed = [(date: day(1), speeds: [9.0, 4.0])]
            + (2..<6).map { (date: day($0 * 5), speeds: [Double]([4.0])) }
        let est = LTPaceEstimate.estimate(runs: skewed, asOf: Date())!
        #expect(est.masMps == 4.0)
    }

    @Test func runsOlderThanTheWindowDoNotCount() {
        // Seven runs 50 days apart span 300 days, so no 90-day window anywhere in that
        // history ever holds three — not the current one, and not one to carry forward.
        #expect(LTPaceEstimate.estimate(runs: runs([4.0], count: 7, everyDays: 50),
                                        asOf: Date()) == nil)
    }

    @Test func theValueIsPublishedOnThePaceGrid() {
        let est = LTPaceEstimate.estimate(runs: runs([4.0], count: 5), asOf: Date())!
        let speed = LTPaceEstimate.ltSpeed(mas: est.masMps, fractionOfMAS: fraction)!
        #expect((1000 / speed).truncatingRemainder(dividingBy: LTPaceEstimate.paceGridSeconds) == 0)
    }

    @Test func theFractionIsDerivedFromTheAthletesOwnLTHR() {
        // Max: (176 - 48) / (206 - 48) / 1.035 = 0.78267...
        let f = LTPaceEstimate.fractionOfMAS(lthr: 176, hrRest: 48, hrMax: 206)!
        #expect(abs(f - 128.0 / 158.0 / 1.035) < 1e-12)
        // Nonsense inputs yield no fraction rather than a plausible-looking number.
        #expect(LTPaceEstimate.fractionOfMAS(lthr: 210, hrRest: 48, hrMax: 206) == nil)
        #expect(LTPaceEstimate.fractionOfMAS(lthr: 176, hrRest: 0, hrMax: 206) == nil)
    }

    // MARK: carry-forward

    @Test func aThinnedWindowCarriesTheLastSolidValueForwardUnchanged() {
        // Five runs ending 100 days ago: no window holds enough *now*, so the value
        // that stood then is held exactly as it stood — 313 s/km, the same number the
        // full window gave. Nothing may move it, because nothing measured it.
        let runs = (0..<5).map { (date: day(100 + $0 * 5), speeds: [Double]([4.0])) }
        let est = LTPaceEstimate.estimate(runs: runs, asOf: Date())!
        #expect(est.masMps == 4.0)
        // Memory, not measurement — the screen has to be able to say so.
        #expect(est.confidence == .stale)
    }

    // MARK: codec

    @Test func profileRoundTrips() {
        #expect(LTPaceEstimate.decode(LTPaceEstimate.encode([170: 3.25, 180: 3.5])) == [170: 3.25, 180: 3.5])
    }

    @Test func anEmptyProfileEncodesToNothing() {
        #expect(LTPaceEstimate.encode([:]).isEmpty)
    }
}
