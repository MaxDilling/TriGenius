import Foundation
import Testing
@testable import TriGenius

// Pins `LTHREstimate`. The intensity/power gates, the recency-weighted quantile, the drift
// limit and the carry-forward are the spec — see `ref/threshold_lab/cycling/lthr.py`, the
// lab twin, for how each was derived and what it replaced.
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

    // MARK: Track

    private func at(_ daysAgo: Double) -> Date { Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86_400) }
    private var now: Date { Date(timeIntervalSince1970: 1_000_000) }

    private func effort(_ daysAgo: Double, _ bpm: Double, watts: Double? = nil,
                        hrMax: Double) -> LTHREstimate.Effort {
        .init(date: at(daysAgo), steadyHR: bpm, watts: watts, hrMax: hrMax)
    }

    private func estimate(_ efforts: [LTHREstimate.Effort], hrMax: Double,
                          gate: LTHREstimate.Gate = .heartRate) -> LTHREstimate.Estimate? {
        LTHREstimate.Track(efforts: efforts, gate: gate).estimate(hrMax: hrMax, asOf: now)
    }

    @Test func gatesOutEasyEffortsAndQuantilesTheRest() {
        // HRmax 206 -> gate 173.04. The three easy windows are below it and must not
        // pull the answer down; 176.4 and 175.5 are the only evidence.
        let efforts = [176.4, 175.5, 161.9, 160.2, 152.9].enumerated().map {
            effort(Double($0.offset) * 3, $0.element, hrMax: 206)
        }
        let r = estimate(efforts, hrMax: 206)!
        #expect(r.effortCount == 2)
        // The easy three are gone, so the answer sits on the two that qualified rather
        // than being dragged toward 152. With only two, q0.75 lands on the upper one.
        #expect(r.bpm == 176.4)
    }

    @Test func neverReturnsTheMaximum() {
        // Four equal-age efforts; q0.75 of {170,172,174,176} interpolates to 175,
        // strictly below the 176 a rolling maximum would report.
        let r = estimate([170.0, 172, 174, 176].map { effort(1, $0, hrMax: 200) }, hrMax: 200)!
        #expect(r.bpm == 175)
        #expect(r.confidence == .anchored)
    }

    @Test func thinPoolIsLabelledNotSuppressed() {
        let r = estimate([effort(1, 176, hrMax: 200)], hrMax: 200)!
        #expect(r.bpm == 176)
        #expect(r.confidence == .thin)
    }

    @Test func eachEffortIsGatedAgainstItsOwnDaysHRMax() {
        // 170 clears 0.84 × 200 = 168, the gate of its day; against today's 205 (172.2)
        // it would not.
        #expect(estimate([effort(100, 170, hrMax: 200)], hrMax: 205)?.bpm == 170)
    }

    @Test func noSessionCarriesMoreThanAQuarterOfTheWeight() {
        // Uncapped, today's 190 (weight 1) outweighs three 300-day-old efforts (0.2647 each)
        // and q0.75 lands on it. Capped it weighs 0.2676 after four passes, so q0.75 of
        // {170, 172, 174, 190} sits just past halfway between 174 and 190.
        let efforts = [effort(300, 170, hrMax: 200), effort(300, 172, hrMax: 200),
                       effort(300, 174, hrMax: 200), effort(0, 190, hrMax: 200)]
        #expect(abs(estimate(efforts, hrMax: 200)!.bpm - 182.0863371465573) < 1e-9)
    }

    @Test func anAnchoredPoolMovesAtMostOneBpmPerMonth() {
        // Four efforts at 180 anchor the pool 37 days ago; four at 190 from 10 days ago
        // pull the quantile up to 190, but the series may only climb 1/30 bpm a day since.
        let efforts = [40.0, 39, 38, 37].map { effort($0, 180, hrMax: 200) }
            + [10.0, 9, 8, 7].map { effort($0, 190, hrMax: 200) }
        #expect(abs(estimate(efforts, hrMax: 200)!.bpm - (180 + 37.0 / 30)) < 1e-9)
    }

    @Test func powerGateRejectsAHighHeartRateAtLowWatts() {
        // The real failure this gate exists for: 168 W at 180 bpm against 297 W at 171.
        // On watts the easy ride is 57 % of the best and drops out, so 171 stands.
        let efforts = [effort(2, 170.9, watts: 296.7, hrMax: 206),
                       effort(1, 180.1, watts: 168.3, hrMax: 206)]
        let r = estimate(efforts, hrMax: 206, gate: .power)!
        #expect(r.bpm == 170.9)
        #expect(r.effortCount == 1)
    }

    /// A window holding no hard effort makes the relative power gate its own reference:
    /// the hardest easy ride sets the bar, 85 % of it admits the rest of the easy
    /// riding, and the aggregate lands at a jogging heart rate. On real data that ran
    /// for eight months at 73–79 % of HRmax while calling itself anchored.
    @Test func anAggregateBelowThePlausibilityFloorIsRefused() {
        let easy = (1...6).map { effort(Double($0), 150, watts: 160, hrMax: 206) }
        // 150 / 206 = 0.728. Nothing qualifies at any date, so only the population
        // fraction is left — which `PerformanceHistory` refuses in turn, leaving the
        // athlete's own LTHR to answer for the bike.
        #expect(estimate(easy, hrMax: 206, gate: .power)?.confidence == .rough)
        // 171 / 206 = 0.830 — the measured cycling value on this athlete — stands.
        let hard = (1...6).map { effort(Double($0), 171, watts: 290, hrMax: 206) }
        #expect(estimate(hard, hrMax: 206, gate: .power)?.bpm == 171)
    }

    @Test func carriesForwardRatherThanFallingToTheFraction() {
        // The only qualifying effort is two years old, outside the 365-day window. The
        // answer holds at its value and says so, instead of dropping to 0.85 * HRmax.
        let r = estimate([effort(700, 176, hrMax: 200)], hrMax: 200)!
        #expect(r.bpm == 176)
        #expect(r.confidence == .stale)
    }

    @Test func fractionOnlyWhenNothingEverQualified() {
        let r = estimate([], hrMax: 200)!
        #expect(r.bpm == 170)          // 0.85 * 200
        #expect(r.confidence == .rough)
    }

    @Test func readingsAboveHRMaxAreDiscardedAsSensorFaults() {
        // 220 with a true max of 206 is impossible; it must not become the estimate.
        let r = estimate([220.0, 176.4].map { effort(1, $0, hrMax: 206) }, hrMax: 206)!
        #expect(r.bpm == 176.4)
    }

    @Test func noHRMaxYieldsNoEstimate() {
        #expect(estimate([effort(1, 180, hrMax: 200)], hrMax: 0) == nil)
    }
}
