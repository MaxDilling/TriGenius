import Foundation

// MARK: - Lactate-threshold HR estimated from HRmax + sustained efforts

/// Recovers an LTHR for watches that never detect one (fēnix 6 Pro and older).
///
/// HRmax is an **input**, not something inferred: athletes generally know it, it
/// barely moves with training, and knowing it makes artifact rejection exact — a
/// reading above the true maximum is by definition a sensor fault. Age formulas are
/// deliberately not used; they under-predict trained athletes by 7–19 bpm.
///
/// Derivation, rejected alternatives and the validation limits:
/// `ref/threshold_lab/cycling/FINDINGS.md`, "LTHR rebuilt".
nonisolated enum LTHREstimate {

    /// LTHR sits at 85–92 % of HRmax in trained athletes. The conservative end is
    /// deliberate: this is reached only when *no* effort has ever cleared the gate, and
    /// over-reading LTHR inflates every HR zone boundary and the HR-derived TL with it.
    ///
    /// It is never combined with observed evidence. Taking `max(fraction, observed)`
    /// buried both reference athletes' measured cycling values — one population constant
    /// cannot serve two sports, and cycling LTHR runs 5–10 bpm under running LTHR.
    static let fractionOfHRMax = 0.85

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
    ///
    /// At 180 days one reference athlete's series swung over 16.9 bpm as single efforts
    /// entered and left a thin pool; 365 halves that *and* lands closer to her measured
    /// value, so the length is not a stability-for-accuracy trade. Longer still was
    /// rejected: with this kernel's tail, two-season-old efforts keep a fifth of full
    /// weight, long enough to outlast a real change in the athlete.
    static let historyDays = 365

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

    /// One observed steady effort, and the power held across the same 20 minutes when
    /// the sport measures it.
    struct Effort: Sendable, Equatable {
        let date: Date
        let steadyHR: Double
        let watts: Double?

        init(date: Date, steadyHR: Double, watts: Double? = nil) {
            self.date = date; self.steadyHR = steadyHR; self.watts = watts
        }
    }

    /// How hard an effort had to be before it says anything about a threshold.
    ///
    /// The sports are not symmetric and the difference is not cosmetic. On a power sport
    /// the intensity is *measured*, so the gate runs on watts; a heart-rate gate cannot
    /// separate a threshold effort from a bad strap, and on real data it did not — one
    /// ride at 57 % of the athlete's test power but 9 bpm *higher* heart rate set his
    /// cycling LTHR 11 bpm too high, having cleared every artifact filter because its
    /// window was stable and its peak below HRmax.
    enum Gate: Sendable { case heartRate, power }

    struct Estimate: Sendable, Equatable {
        let bpm: Double
        let confidence: EstimateConfidence
        let effortCount: Int
    }

    /// Fraction of HRmax an effort must reach before it carries threshold information.
    /// Easy running below it drags a quantile far under threshold. Both reference
    /// athletes' pools are bimodal — one steps straight from 175 to 162 bpm — so the
    /// corridor this sits in is wide, not a fitted edge.
    static let effortGateFractionOfHRMax = 0.84

    /// Fraction of the athlete's own best 20-minute power in the window that a ride must
    /// reach. Deliberately not a fraction of a configured FTP: that value is back-solved
    /// and swings by tens of watts on an easy ride.
    static let powerGateFractionOfBest = 0.85

    /// Not the maximum. One hot day or one mis-read window would set the value and, inside
    /// the window, never let it fall again.
    static let quantile = 0.75

    /// An aggregate below this fraction of HRmax is not a threshold, and is refused.
    ///
    /// The check exists for `Gate.power`, whose reference is *relative* — the athlete's
    /// own best 20-minute power inside the window. That is what makes it immune to a bad
    /// strap, and also what makes it degenerate when the window holds no hard effort at
    /// all: the hardest easy ride becomes its own reference, 85 % of it admits the rest
    /// of the easy riding, and the quantile settles on a jogging heart rate. On real
    /// data that ran for eight months at 151-162 bpm — 73-79 % of HRmax — labelled
    /// `.anchored`, until one 297 W test arrived and moved it to 170.9 in a day.
    ///
    /// LTHR sits at 85-92 % of HRmax and cycling LTHR 5-10 bpm under running, so the
    /// floor is set under the *cycling* case rather than the running one: it clears both
    /// reference athletes' measured cycling values (0.830 and 0.816) and rejects that
    /// entire degenerate stretch. Refusing is the point — with nothing above the floor
    /// the athlete's own LTHR on record answers instead, which is what "not measured
    /// yet" should look like. Inert on `Gate.heartRate`, whose efforts already have to
    /// clear `effortGateFractionOfHRMax`.
    static let minimumFractionOfHRMax = 0.80

    /// Longer than the pace estimator's kernel: LTHR moves slowly enough that a season of
    /// evidence is all one level.
    static let ageTauDays = 180.0

    /// Below this the answer rests on one or two sessions. It is a label, not a filter —
    /// suppressing the value would leave nothing at all for an athlete who clears the gate
    /// twice in six months, which is a real case rather than a pathological one.
    static let minimumEfforts = 4

    /// LTHR from a known HRmax and the steady efforts observed in one sport.
    ///
    /// Efforts are gated to the ones hard enough to inform a threshold, then reduced by a
    /// recency-weighted quantile. **Filter `efforts` to a single sport before calling.**
    /// Pooling sports reads a cycling ride as a running threshold, and the two differ by
    /// 5–10 bpm in the same athlete.
    ///
    /// With no gated effort in the window the last answer that had one is carried forward
    /// as `.stale`, never replaced by the population fraction: that fraction is a different
    /// quantity, and substituting it mid-series draws a cliff that reads as a change in the
    /// athlete when it only means the window went quiet. Only when nothing has *ever*
    /// qualified does the fraction stand, as `.rough`.
    static func estimate(efforts: [Effort], hrMax: Double, gate: Gate,
                         asOf: Date) -> Estimate? {
        guard hrMax > 0 else { return nil }
        let usable = efforts
            .filter { $0.steadyHR > 0 && $0.steadyHR <= hrMax && $0.date <= asOf }
            .sorted { $0.date < $1.date }

        if let value = windowed(usable, hrMax: hrMax, gate: gate, endingAt: asOf) {
            return value
        }
        for effort in usable.reversed() {
            if let held = windowed(usable, hrMax: hrMax, gate: gate, endingAt: effort.date) {
                return Estimate(bpm: held.bpm, confidence: .stale, effortCount: 0)
            }
        }
        return Estimate(bpm: fractionOfHRMax * hrMax, confidence: .rough, effortCount: 0)
    }

    private static func windowed(_ efforts: [Effort], hrMax: Double, gate: Gate,
                                 endingAt end: Date) -> Estimate? {
        let cutoff = end.addingTimeInterval(-Double(historyDays) * 86_400)
        let window = efforts.filter { $0.date > cutoff && $0.date <= end }
        let gated: [Effort]
        switch gate {
        case .heartRate:
            gated = window.filter { $0.steadyHR >= effortGateFractionOfHRMax * hrMax }
        case .power:
            let powered = window.filter { ($0.watts ?? 0) > 0 }
            guard let best = powered.compactMap(\.watts).max() else { return nil }
            gated = powered.filter { ($0.watts ?? 0) >= powerGateFractionOfBest * best }
        }
        guard !gated.isEmpty else { return nil }

        let weights = gated.map {
            RecencyWeighting.weight(ageDays: end.timeIntervalSince($0.date) / 86_400,
                                    tauDays: ageTauDays)
        }
        guard let bpm = RecencyWeighting.quantile(gated.map(\.steadyHR),
                                                  weights: weights, q: quantile),
              bpm >= minimumFractionOfHRMax * hrMax else { return nil }
        return Estimate(bpm: bpm,
                        confidence: gated.count >= minimumEfforts ? .anchored : .thin,
                        effortCount: gated.count)
    }
}
