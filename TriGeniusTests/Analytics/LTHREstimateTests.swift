import Testing
@testable import TriGenius

// Pins `LTHREstimate`. The two-branch `max` and the drift/placement filters are the
// spec — see `ref/ftp_lab/FINDINGS.md` for how each was derived.
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

    @Test func takesTheLargerOfTheTwoBounds() {
        // Max: HRmax 206 -> floor 181.28; his best steady window 181.7 wins.
        let a = LTHREstimate.estimate(hrMax: 206, steadyWindows: [181.7, 170])!
        #expect(a.bpm == 181.7)
        // Lea: HRmax 202 -> floor 177.76; her 186.3 wins.
        let b = LTHREstimate.estimate(hrMax: 202, steadyWindows: [186.3])!
        #expect(b.bpm == 186.3)
    }

    @Test func fallsBackToTheFractionWhenNoEffortExists() {
        let r = LTHREstimate.estimate(hrMax: 200, steadyWindows: [])!
        #expect(r.bpm == 176)          // 0.88 * 200
        #expect(r.isAnchored == false)
    }

    @Test func anchoredOnlyWithANearMaximalEffort() {
        // 186.3 / 202 = 0.922 -> anchored.
        #expect(LTHREstimate.estimate(hrMax: 202, steadyWindows: [186.3])!.isAnchored)
        // 175 / 202 = 0.866 -> the athlete never went hard; a floor, not a reading.
        #expect(LTHREstimate.estimate(hrMax: 202, steadyWindows: [175])!.isAnchored == false)
    }

    @Test func readingsAboveHRMaxAreDiscardedAsSensorFaults() {
        // 220 with a true max of 206 is impossible; it must not become the estimate.
        let r = LTHREstimate.estimate(hrMax: 206, steadyWindows: [220, 181.7])!
        #expect(r.bpm == 181.7)
    }

    @Test func noHRMaxYieldsNoEstimate() {
        #expect(LTHREstimate.estimate(hrMax: 0, steadyWindows: [180]) == nil)
    }
}
