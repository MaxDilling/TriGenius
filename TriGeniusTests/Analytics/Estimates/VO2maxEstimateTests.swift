import Foundation
import Testing
@testable import TriGenius

// Pins `VO2maxEstimate`. The reserve scaling, the duration normalisation and the filter
// are the spec. The filter's pins come from the lab reference on the same rides
// (`ref/threshold_lab/cycling/statespace.py`, `estimator()`), which is what makes the
// cohort validation transfer.
struct VO2maxEstimateTests {

    private let hrMax = 206.0, hrRest = 48.0, mass = 75.0

    // MARK: readings

    @Test func reconstructsFromCostAndUnusedReserve() {
        // 250 W / 75 kg -> 11.016 * 250 / 75 + 7 = 43.72 ml/kg/min at %HRR
        // (160 - 48) / (206 - 48) = 0.70886, so 3.5 + (43.72 - 3.5) / 0.70886 = 60.2389.
        // At the reference duration the normalisation is a no-op.
        let r = VO2maxEstimate.reading(seconds: 480, watts: 250, heartRate: 160,
                                       hrMax: hrMax, hrRest: hrRest, massKg: mass)
        #expect(abs(r! - 60.238928571428566) < 1e-12)
    }

    @Test func longerEffortsAreNormalisedUpToTheReference() {
        // Within a ride a 1200 s effort reads lower than a 480 s one, because HR has
        // drifted; the normalisation scales it up: 60.2389 * (1200/480)^0.080 = 64.8205.
        let r = VO2maxEstimate.reading(seconds: 1200, watts: 250, heartRate: 160,
                                       hrMax: hrMax, hrRest: hrRest, massKg: mass)
        #expect(abs(r! - 64.8205093686543) < 1e-12)
    }

    @Test func effortsOutsideTheReserveBandDoNotCount() {
        // 0.60-0.95 of a 158 bpm reserve is 142.8-198.1 bpm.
        #expect(VO2maxEstimate.reading(seconds: 480, watts: 150, heartRate: 120,
                                       hrMax: hrMax, hrRest: hrRest, massKg: mass) == nil)
        #expect(VO2maxEstimate.reading(seconds: 480, watts: 400, heartRate: 202,
                                       hrMax: hrMax, hrRest: hrRest, massKg: mass) == nil)
    }

    @Test func missingBodyMassYieldsNothing() {
        #expect(VO2maxEstimate.reading(seconds: 480, watts: 250, heartRate: 160,
                                       hrMax: hrMax, hrRest: hrRest, massKg: 0) == nil)
    }

    @Test func hrMaxDeclinesWithAgeInBothDirections() {
        // 0.7 bpm/year: two years before the measurement it was 1.4 bpm higher.
        let measured = Date(timeIntervalSince1970: 1_000_000_000)
        let earlier = measured.addingTimeInterval(-2 * 365.25 * 86_400)
        #expect(abs(VO2maxEstimate.hrMax(206, measured: measured, on: earlier) - 207.4) < 1e-9)
        #expect(VO2maxEstimate.hrMax(206, measured: measured, on: measured) == 206)
    }

    @Test func detrainingStartsAfterTheWeeklyRhythm() {
        #expect(VO2maxEstimate.detraining(idleDays: 5) == 0)
        #expect(VO2maxEstimate.detraining(idleDays: 7) == 0)
        // 0.064 * (exp(-7/13.2) - exp(-14/13.2))
        #expect(abs(VO2maxEstimate.detraining(idleDays: 14) - 0.015499566773199941) < 1e-15)
    }

    // MARK: the filter

    @Test func boundedMinimiserTakesSciPysSteps() {
        // scipy.optimize.minimize_scalar(f, bounds=(-2, 3), method="bounded",
        // options={"xatol": 1e-3}).x for f = (x - 1)^2 + 0.1 sin(5x).
        let x = VO2maxEstimate.minimizeBounded((-2, 3)) { ($0 - 1) * ($0 - 1) + 0.1 * sin(5 * $0) }
        #expect(abs(x - 0.9680855813449294) < 1e-12)
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func day(_ d: Double) -> Date { t0.addingTimeInterval(d * 86_400) }

    /// Eight rides three days apart, a 13-day gap before the seventh, two efforts each;
    /// a run on days 19 and 22 falls inside the gap.
    private var rides: [VO2maxEstimate.Ride] {
        let watts = [220.0, 260, 210, 250, 200, 265, 230, 245]
        let hrs = [150.0, 152, 149, 155, 151, 156, 150, 149]
        return (0 ..< 8).map { k in
            let date = day(Double(3 * k + (k >= 6 ? 10 : 0)))
            return .init(date: date,
                         profile: [480: (watts[k], hrs[k]), 1200: (watts[k] - 15, hrs[k] + 4)],
                         hrMax: VO2maxEstimate.hrMax(190, measured: day(30), on: date),
                         hrRest: 50, massKg: 70)
        }
    }

    private func track(_ rides: [VO2maxEstimate.Ride]) -> VO2maxEstimate.Track? {
        VO2maxEstimate.track(rides: rides, sessions: [day(19), day(22)])
    }

    @Test func filterMatchesTheLabReference() throws {
        let track = try #require(track(rides))
        #expect(abs(track.rideNoise - 0.001660577000657237) < 1e-12)
        for (d, log, sd) in [(12.0, 4.118920085655162, 0.03136997050803023),
                             (36.0, 4.143420222908415, 0.0281672772535433),
                             (80.0, 4.107324160490761, 0.04903387838971259)] {
            let state = try #require(track.state(at: day(d)))
            #expect(abs(state.log - log) < 1e-10)
            #expect(abs(state.sd - sd) < 1e-10)
        }
    }

    @Test func belowFiveRidesThereIsNoLevel() throws {
        #expect(track(Array(rides.prefix(4))) == nil)
        // Five rides: the level exists from the fifth ride's day, not before.
        let track = try #require(track(Array(rides.prefix(5))))
        #expect(track.state(at: day(11)) == nil)
        #expect(track.state(at: day(12)) != nil)
    }

    @Test func confidenceCountsCalibrationAndStaleness() throws {
        let track = try #require(track(rides))
        #expect(track.confidence(at: day(40)) == .thin)       // < 56 days since the 5th ride, day 12
        #expect(track.confidence(at: day(70)) == .anchored)   // 58 days since; last ride day 31
        #expect(track.confidence(at: day(80)) == .stale)      // 49 days without a ride
    }

    // MARK: profile codec

    @Test func profileRoundTripsThroughItsEncoding() {
        let profile = [480: (watts: 250.4, hr: 160.2), 1200: (watts: 231.1, hr: 168.9)]
        let decoded = VO2maxEstimate.decode(VO2maxEstimate.encode(profile))
        #expect(decoded.count == 2)
        #expect(decoded[480]!.watts == 250.4)
        #expect(decoded[1200]!.hr == 168.9)
    }

    @Test func anEmptyProfileEncodesToNothing() {
        #expect(VO2maxEstimate.encode([:]).isEmpty)
        #expect(VO2maxEstimate.decode("").isEmpty)
    }

    // MARK: Running

    /// The run side is a change of unit, not a second estimator: `LTPaceEstimate` already
    /// scales grade-adjusted speed by the unused heart-rate reserve, which is the %VO2R
    /// scaling in m/s. Only the economy equation is applied here.
    @Test func runningVO2maxIsTheACSMCostOfTheReconstructedMAS() {
        // 4.0 m/s is 240 m/min: 0.2 * 240 + 3.5 = 51.5 ml/kg/min.
        #expect(abs(VO2maxEstimate.running(mas: 4.0)! - 51.5) < 1e-9)
        #expect(VO2maxEstimate.running(mas: 0) == nil)
    }
}
