import Foundation
import Testing
@testable import TriGenius

// Pins `LTPaceEstimate`. The band, the bucket gate, the per-run best and the filter are the
// spec — see `ref/threshold_lab/running/FINDINGS.md` §8 for how each was measured. Expected
// values are hand-computed from the formulas, the filter's from the lab reference.
struct LTPaceEstimateTests {

    private let hrMax = 206.0, hrRest = 48.0   // reserve 158 bpm

    /// 1 Hz `(value, seconds)` samples, as the sources shape them for zone bucketing.
    private func flat(_ value: Double, minutes: Int) -> [NormalizedStream.Sample] {
        (0..<(minutes * 60)).map { _ in (value: value, seconds: 1.0) }
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

    // MARK: reading

    @Test func aRunReadsItsFastestInBandBucketScaledByTheUnusedReserve() {
        // max(3.2 * 158 / (170 - 48), 3.3 * 158 / (175 - 48)) = max(4.14426, 4.10551)
        let mas = LTPaceEstimate.reading(profile: [170: 3.2, 175: 3.3], hrMax: hrMax, hrRest: hrRest)
        #expect(abs(mas! - 3.2 * 158 / 122) < 1e-12)
    }

    @Test func aRunNeedsTwoInBandBuckets() {
        // Band is 164.8 - 195.7 bpm at HRmax 206: 150 and 200 are outside however fast they
        // were, which leaves one bucket — one minute is not an observation.
        #expect(LTPaceEstimate.reading(profile: [150: 4.5, 170: 3.2, 200: 5.0],
                                       hrMax: hrMax, hrRest: hrRest) == nil)
    }

    @Test func missingRestingHeartRateYieldsNoReading() {
        #expect(LTPaceEstimate.reading(profile: [170: 3.2, 175: 3.3], hrMax: hrMax, hrRest: 0) == nil)
    }

    @Test func theFractionIsTheReserveHeldAtLTHR() {
        // Max: (176 - 48) / (206 - 48) — no level constant divides it.
        let f = LTPaceEstimate.fractionOfMAS(lthr: 176, hrRest: 48, hrMax: 206)!
        #expect(abs(f - 128.0 / 158.0) < 1e-12)
        // Nonsense inputs yield no fraction rather than a plausible-looking number.
        #expect(LTPaceEstimate.fractionOfMAS(lthr: 210, hrRest: 48, hrMax: 206) == nil)
        #expect(LTPaceEstimate.fractionOfMAS(lthr: 176, hrRest: 0, hrMax: 206) == nil)
    }

    @Test func theValueIsPublishedOnThePaceGrid() {
        // 4.0 * 0.8 = 3.2 m/s = 312.5 s/km, snapped to the 1 s/km grid -> 313.
        #expect(abs(1000 / LTPaceEstimate.ltSpeed(mas: 4.0, fractionOfMAS: 0.8)! - 313) < 1e-9)
    }

    // MARK: the filter

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func day(_ d: Double) -> Date { t0.addingTimeInterval(d * 86_400) }

    /// Eight runs three days apart, a 13-day gap before the seventh, two in-band buckets
    /// each; sessions of another sport on days 19 and 22 fall inside the gap.
    private var runs: [LTPaceEstimate.Run] {
        let fast = [3.30, 3.45, 3.25, 3.40, 3.20, 3.50, 3.35, 3.42]
        return (0 ..< 8).map { k in
            let date = day(Double(3 * k + (k >= 6 ? 10 : 0)))
            return .init(date: date, profile: [160: fast[k], 166: fast[k] + 0.12],
                         hrMax: VO2maxEstimate.hrMax(190, measured: day(30), on: date), hrRest: 50)
        }
    }

    private func track(_ runs: [LTPaceEstimate.Run]) -> VO2maxEstimate.Track? {
        LTPaceEstimate.track(runs: runs, sessions: [day(19), day(22)])
    }

    @Test func filterMatchesTheLabReference() throws {
        let track = try #require(track(runs))
        #expect(abs(track.rideNoise - 0.0005501488549304128) < 1e-12)
        for (d, log, sd) in [(12.0, 1.4428074340439363, 0.021354772687405734),
                             (36.0, 1.4515618310710385, 0.022432400215572537),
                             (80.0, 1.415465768653385, 0.04597975969370397)] {
            let state = try #require(track.state(at: day(d)))
            #expect(abs(state.log - log) < 1e-10)
            #expect(abs(state.sd - sd) < 1e-10)
        }
    }

    @Test func runsWithoutAnObservationDoNotCount() throws {
        // Five runs, one of them holding a single in-band bucket: four observations, below
        // the filter's five.
        var five = Array(runs.prefix(5))
        five[2] = .init(date: five[2].date, profile: [160: 3.25], hrMax: five[2].hrMax, hrRest: 50)
        #expect(track(five) == nil)
        #expect(track(Array(runs.prefix(5))) != nil)
    }

    // MARK: codec

    @Test func profileRoundTrips() {
        #expect(LTPaceEstimate.decode(LTPaceEstimate.encode([170: 3.25, 180: 3.5])) == [170: 3.25, 180: 3.5])
    }

    @Test func anEmptyProfileEncodesToNothing() {
        #expect(LTPaceEstimate.encode([:]).isEmpty)
    }
}
