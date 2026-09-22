import Foundation
import Testing
@testable import TriGenius

// Pins `VO2maxEstimate`. The reserve scaling, the duration normalisation and the
// top-N age-weighted aggregation are the spec — derivation and the rejected
// aggregations are in `ref/threshold_lab/cycling/FINDINGS.md`.
struct VO2maxEstimateTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private let hrMax = 206.0, hrRest = 48.0, mass = 75.0

    // MARK: readings

    @Test func reconstructsFromCostAndUnusedReserve() {
        // 250 W / 75 kg -> 11.016 * 250 / 75 + 7 = 43.72 ml/kg/min at %HRR
        // (160 - 48) / (206 - 48) = 0.70886, so 3.5 + (43.72 - 3.5) / 0.70886 = 60.2389.
        // At the reference duration the normalisation is a no-op.
        let e = VO2maxEstimate.Effort(date: now, seconds: 480, watts: 250, heartRate: 160)
        let r = VO2maxEstimate.readings(efforts: [e], hrMax: hrMax, hrRest: hrRest, massKg: mass)
        #expect(r.count == 1)
        #expect(abs(r[0].vo2max - 60.238928571428566) < 1e-12)
    }

    @Test func longerEffortsAreNormalisedUpToTheReference() {
        // The same power and heart rate held for 1200 s reports a *lower* VO2max,
        // because HR has drifted; the normalisation is what makes the two comparable.
        let long = VO2maxEstimate.Effort(date: now, seconds: 1200, watts: 250, heartRate: 160)
        let r = VO2maxEstimate.readings(efforts: [long], hrMax: hrMax, hrRest: hrRest, massKg: mass)
        #expect(abs(r[0].vo2max - 55.98117865436648) < 1e-12)
    }

    @Test func effortsOutsideTheReserveBandDoNotCount() {
        // 0.60-0.95 of a 158 bpm reserve is 142.8-198.1 bpm.
        let easy = VO2maxEstimate.Effort(date: now, seconds: 480, watts: 150, heartRate: 120)
        let sprint = VO2maxEstimate.Effort(date: now, seconds: 480, watts: 400, heartRate: 202)
        #expect(VO2maxEstimate.readings(efforts: [easy, sprint], hrMax: hrMax,
                                        hrRest: hrRest, massKg: mass).isEmpty)
    }

    @Test func missingBodyMassYieldsNothing() {
        let e = VO2maxEstimate.Effort(date: now, seconds: 480, watts: 250, heartRate: 160)
        #expect(VO2maxEstimate.readings(efforts: [e], hrMax: hrMax, hrRest: hrRest,
                                        massKg: 0).isEmpty)
    }

    // MARK: estimate

    private func efforts(_ count: Int, watts: Double = 250, hr: Double = 160,
                         spacingDays: Double = 1) -> [VO2maxEstimate.Effort] {
        (0 ..< count).map {
            .init(date: ago(Double($0) * spacingDays), seconds: 480, watts: watts, heartRate: hr)
        }
    }

    @Test func identicalEffortsResolveToTheirOwnValue() {
        let r = VO2maxEstimate.estimate(efforts: efforts(20), hrMax: hrMax, hrRest: hrRest,
                                        massKg: mass, asOf: now)!
        #expect(abs(r.vo2max - 60.238928571428566) < 1e-9)
        #expect(r.effortCount == 20)
        #expect(r.confidence == .anchored)
    }

    @Test func belowTheMinimumThereIsNoEstimate() {
        #expect(VO2maxEstimate.estimate(efforts: efforts(19), hrMax: hrMax, hrRest: hrRest,
                                        massKg: mass, asOf: now) == nil)
    }

    @Test func selectsTheBestEffortsSoEasyVolumeIsInert() {
        // Twenty hard efforts plus forty easy ones: the easy ones are inside the band
        // but never enter the top ten, so they cannot dilute the answer.
        let pool = efforts(20, watts: 250) + efforts(40, watts: 180, hr: 150)
        let r = VO2maxEstimate.estimate(efforts: pool, hrMax: hrMax, hrRest: hrRest,
                                        massKg: mass, asOf: now)!
        #expect(abs(r.vo2max - 60.238928571428566) < 1e-9)
        #expect(r.effortCount == 60)
    }

    @Test func evidenceOlderThanATrainingBlockIsFlaggedStale() {
        let old = efforts(20, spacingDays: 1).map {
            VO2maxEstimate.Effort(date: $0.date.addingTimeInterval(-60 * 86_400),
                                  seconds: $0.seconds, watts: $0.watts, heartRate: $0.heartRate)
        }
        let r = VO2maxEstimate.estimate(efforts: old, hrMax: hrMax, hrRest: hrRest,
                                        massKg: mass, asOf: now)!
        #expect(r.confidence == .stale)
        #expect(r.evidenceAgeDays >= VO2maxEstimate.staleDays)
    }

    @Test func effortsAfterTheAsOfDateAreNotVisible() {
        let future = efforts(20).map {
            VO2maxEstimate.Effort(date: $0.date.addingTimeInterval(10 * 86_400),
                                  seconds: $0.seconds, watts: $0.watts, heartRate: $0.heartRate)
        }
        #expect(VO2maxEstimate.estimate(efforts: future, hrMax: hrMax, hrRest: hrRest,
                                        massKg: mass, asOf: now) == nil)
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
