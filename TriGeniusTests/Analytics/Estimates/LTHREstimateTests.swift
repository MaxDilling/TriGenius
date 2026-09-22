import Foundation
import Testing
@testable import TriGenius

// Pins `LTHREstimate`. The intensity/power gates, the recency-weighted quantile and the
// carry-forward are the spec — see `ref/threshold_lab/cycling/FINDINGS.md`, "LTHR
// rebuilt", for how each was derived and what it replaced.
struct LTHREstimateTests {

    /// `(bpm, seconds)` samples at 1 Hz, as the sources shape them for zone bucketing.
    private func flat(_ bpm: Double, minutes: Int) -> [NormalizedStream.Sample] {
        (0..<(minutes * 60)).map { _ in (value: bpm, seconds: 1.0) }
    }

    private func ramp(_ from: Double, _ to: Double, minutes: Int) -> [NormalizedStream.Sample] {
        let n = minutes * 60
        return (0..<n).map { (value: from + (to - from) * Double($0) / Double(n - 1), seconds: 1.0) }
    }

    // MARK: steadyWindow

    @Test func flatEffortYieldsItsOwnMean() {
        #expect(LTHREstimate.steadyWindow(flat(170, minutes: 25))! == 170)
    }

    @Test func tooShortYieldsNothing() {
        #expect(LTHREstimate.steadyWindow(flat(170, minutes: 19)) == nil)
    }

    @Test func risingWindowIsRejected() {
        // 20 min climbing 160 -> 190 is +1.5 bpm/min, ten times the steady cutoff:
        // the athlete was above threshold, so the window must not count.
        #expect(LTHREstimate.steadyWindow(ramp(160, 190, minutes: 20)) == nil)
    }

    @Test func driftBelowTheCutoffStillCounts() {
        // +2 bpm over 20 min = 0.1 bpm/min, inside normal thermal drift.
        let v = LTHREstimate.steadyWindow(ramp(169, 171, minutes: 20))
        #expect(v != nil && abs(v! - 170) < 0.01)
    }

    @Test func windowStartingTooLateIsRejected() {
        // A flat window is only comparable to a 30-min time trial if it starts early;
        // later, accumulated cardiac drift has already inflated it.
        // The hard block starts at 45 min, past the limit — so it is invisible and
        // only the easy early stretch qualifies. The estimate must not see 180 here.
        let late = flat(120, minutes: 45) + flat(180, minutes: 25)
        #expect(LTHREstimate.steadyWindow(late)! == 120)
        // The same high block starting inside the limit is accepted.
        let early = flat(120, minutes: 30) + flat(180, minutes: 25)
        #expect(LTHREstimate.steadyWindow(early)! == 180)
    }

    // MARK: estimate

    private func at(_ daysAgo: Double) -> Date { Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86_400) }
    private var now: Date { Date(timeIntervalSince1970: 1_000_000) }

    @Test func gatesOutEasyEffortsAndQuantilesTheRest() {
        // HRmax 206 -> gate 173.04. The three easy windows are below it and must not
        // pull the answer down; 176.4 and 175.5 are the only evidence.
        let efforts = [176.4, 175.5, 161.9, 160.2, 152.9].enumerated().map {
            LTHREstimate.Effort(date: at(Double($0.offset) * 3), steadyHR: $0.element)
        }
        let r = LTHREstimate.estimate(efforts: efforts, hrMax: 206, gate: .heartRate, asOf: now)!
        #expect(r.effortCount == 2)
        // The easy three are gone, so the answer sits on the two that qualified rather
        // than being dragged toward 152. With only two, q0.75 lands on the upper one.
        #expect(r.bpm == 176.4)
    }

    @Test func neverReturnsTheMaximum() {
        // Four equal-age efforts; q0.75 of {170,172,174,176} interpolates to 175,
        // strictly below the 176 a rolling maximum would report.
        let efforts = [170.0, 172, 174, 176].map {
            LTHREstimate.Effort(date: at(1), steadyHR: $0)
        }
        let r = LTHREstimate.estimate(efforts: efforts, hrMax: 200, gate: .heartRate, asOf: now)!
        #expect(r.bpm == 175)
        #expect(r.confidence == .anchored)
    }

    @Test func thinPoolIsLabelledNotSuppressed() {
        let r = LTHREstimate.estimate(efforts: [.init(date: at(1), steadyHR: 176)],
                                      hrMax: 200, gate: .heartRate, asOf: now)!
        #expect(r.bpm == 176)
        #expect(r.confidence == .thin)
    }

    @Test func powerGateRejectsAHighHeartRateAtLowWatts() {
        // The real failure this gate exists for: 168 W at 180 bpm against 297 W at 171.
        // On watts the easy ride is 57 % of the best and drops out, so 171 stands.
        let efforts = [
            LTHREstimate.Effort(date: at(2), steadyHR: 170.9, watts: 296.7),
            LTHREstimate.Effort(date: at(1), steadyHR: 180.1, watts: 168.3),
        ]
        let r = LTHREstimate.estimate(efforts: efforts, hrMax: 206, gate: .power, asOf: now)!
        #expect(r.bpm == 170.9)
        #expect(r.effortCount == 1)
    }

    /// A window holding no hard effort makes the relative power gate its own reference:
    /// the hardest easy ride sets the bar, 85 % of it admits the rest of the easy
    /// riding, and the aggregate lands at a jogging heart rate. On real data that ran
    /// for eight months at 73–79 % of HRmax while calling itself anchored.
    @Test func anAggregateBelowThePlausibilityFloorIsRefused() {
        let easy = (1...6).map { LTHREstimate.Effort(date: at(Double($0)), steadyHR: 150, watts: 160) }
        // 150 / 206 = 0.728. Nothing qualifies at any date, so only the population
        // fraction is left — which `PerformanceHistory` refuses in turn, leaving the
        // athlete's own LTHR to answer for the bike.
        #expect(LTHREstimate.estimate(efforts: easy, hrMax: 206, gate: .power,
                                      asOf: now)?.confidence == .rough)
        // 171 / 206 = 0.830 — the measured cycling value on this athlete — stands.
        let hard = (1...6).map { LTHREstimate.Effort(date: at(Double($0)), steadyHR: 171, watts: 290) }
        #expect(LTHREstimate.estimate(efforts: hard, hrMax: 206, gate: .power,
                                      asOf: now)?.bpm == 171)
    }

    @Test func carriesForwardRatherThanFallingToTheFraction() {
        // The only qualifying effort is two years old, outside the 365-day window. The
        // answer holds at its value and says so, instead of dropping to 0.85 * HRmax.
        let old = LTHREstimate.Effort(date: at(700), steadyHR: 176)
        let r = LTHREstimate.estimate(efforts: [old], hrMax: 200, gate: .heartRate, asOf: now)!
        #expect(r.bpm == 176)
        #expect(r.confidence == .stale)
    }

    @Test func fractionOnlyWhenNothingEverQualified() {
        let r = LTHREstimate.estimate(efforts: [], hrMax: 200, gate: .heartRate, asOf: now)!
        #expect(r.bpm == 170)          // 0.85 * 200
        #expect(r.confidence == .rough)
    }

    @Test func readingsAboveHRMaxAreDiscardedAsSensorFaults() {
        // 220 with a true max of 206 is impossible; it must not become the estimate.
        let efforts = [220.0, 176.4].map { LTHREstimate.Effort(date: at(1), steadyHR: $0) }
        let r = LTHREstimate.estimate(efforts: efforts, hrMax: 206, gate: .heartRate, asOf: now)!
        #expect(r.bpm == 176.4)
    }

    @Test func noHRMaxYieldsNoEstimate() {
        #expect(LTHREstimate.estimate(efforts: [.init(date: at(1), steadyHR: 180)],
                                      hrMax: 0, gate: .heartRate, asOf: now) == nil)
    }
}
