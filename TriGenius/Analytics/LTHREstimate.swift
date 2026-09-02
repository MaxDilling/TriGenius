import Foundation

// MARK: - Lactate-threshold HR estimated from HRmax + sustained efforts

/// Recovers an LTHR for watches that never detect one (fēnix 6 Pro and older).
///
/// HRmax is an **input**, not something inferred: athletes generally know it, it
/// barely moves with training, and knowing it makes artifact rejection exact — a
/// reading above the true maximum is by definition a sensor fault. Age formulas are
/// deliberately not used; they under-predict trained athletes by 7–19 bpm.
///
/// Derivation, rejected alternatives and the validation limits: `ref/ftp_lab/FINDINGS.md`.
nonisolated enum LTHREstimate {

    /// LTHR sits at 85–92 % of HRmax in trained athletes. The conservative end is
    /// deliberate: this acts as a *floor*, and over-reading LTHR inflates every HR
    /// zone boundary and the HR-derived TL fallback with it.
    static let fractionOfHRMax = 0.88

    /// Friel's threshold protocol measures mean HR over the final 20 min of a 30-min
    /// time trial. This finds the same 20 minutes opportunistically in real training.
    static let windowSeconds = 1200

    /// A window whose HR is flat sits *at* threshold; one whose HR climbs sits
    /// *above* it and its mean overstates LTHR. Below normal thermal drift, above
    /// 20-minute measurement noise.
    static let steadySlopeMaxBpmPerMinute = 0.15

    /// A window must *start* within this much of the activity. Cardiac drift keeps
    /// accumulating, so a flat window late in a long race is a drifted steady state
    /// reading several bpm high — flat within itself, but not comparable to a 30-min
    /// time trial. This bounds the drift exposure to roughly Friel's.
    static let maxWindowStartSeconds = 2400

    /// How far back sustained efforts are gathered. Long on purpose: hard 20-minute
    /// efforts are rare in ordinary training, and LTHR itself moves little — what
    /// improves with fitness is the pace/power at LTHR, not the heart rate.
    static let historyDays = 180

    /// Best *steady* 20-minute mean HR inside one activity, or nil when the activity
    /// holds no qualifying window. Samples are `(bpm, seconds)` as the sources shape
    /// them for zone bucketing; they are expanded to 1 Hz here.
    static func steadyWindow(_ samples: [NormalizedStream.Sample]) -> Double? {
        var hr: [Double] = []
        hr.reserveCapacity(samples.count)
        for s in samples where s.value > 0 {
            // A single reading standing for an implausible span is a recording gap,
            // not a held heart rate; clamp so it cannot dominate a window.
            let seconds = min(max(Int(s.seconds.rounded()), 1), 30)
            for _ in 0..<seconds { hr.append(s.value) }
        }
        let n = windowSeconds
        guard hr.count >= n else { return nil }

        // Prefix sums of h and of i·h make both the mean and the least-squares slope
        // O(1) per window, so the sweep stays linear.
        var sum: [Double] = [0], weighted: [Double] = [0]
        sum.reserveCapacity(hr.count + 1); weighted.reserveCapacity(hr.count + 1)
        for (i, v) in hr.enumerated() {
            sum.append(sum[i] + v)
            weighted.append(weighted[i] + Double(i) * v)
        }
        // Σ(x−x̄)² for x = 0…n−1 in minutes.
        let nd = Double(n)
        let xMean = (nd - 1) / 2
        let xVar = (nd * nd * nd - nd) / 12 / 3600      // /3600: seconds² → minutes²

        var best: Double?
        let lastStart = min(hr.count - n, maxWindowStartSeconds)
        for start in stride(from: 0, through: lastStart, by: 30) {
            let total = sum[start + n] - sum[start]
            let mean = total / nd
            if let b = best, mean <= b { continue }
            // Σ(j·y) with j local to the window, from the global weighted prefix.
            let jy = (weighted[start + n] - weighted[start]) - Double(start) * total
            let cov = (jy - xMean * total) / 60                  // seconds → minutes
            if cov / xVar <= steadySlopeMaxBpmPerMinute { best = mean }
        }
        return best
    }

    /// LTHR from a known HRmax and the steady windows observed in recent training.
    ///
    /// Two lower bounds, whichever is larger. Neither can over-read, and they fail on
    /// opposite conditions: the fraction is right when the athlete's ratio is typical
    /// and low when it is not; the observed window is right when a hard effort exists
    /// and absent when none does.
    ///
    /// `isAnchored` is false when the value rests on the fraction alone — the estimate
    /// is then a floor and must be surfaced as the rougher guess it is.
    static func estimate(hrMax: Double, steadyWindows: [Double]) -> (bpm: Double, isAnchored: Bool)? {
        guard hrMax > 0 else { return nil }
        let floor = fractionOfHRMax * hrMax
        guard let best = steadyWindows.filter({ $0 > 0 && $0 <= hrMax }).max() else {
            return (floor, false)
        }
        return (max(floor, best), best / hrMax >= 0.90)
    }
}
