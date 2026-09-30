import Foundation

// MARK: - Cycling critical power and W′ as one estimate

/// CP and W′ from two signals: heart rate prices the aerobic ceiling and says nothing
/// about the anaerobic battery, and only watts see the battery.
///
/// **CP is aerobic.** `VO2maxEstimate.track` follows VO2max through submaximal riding,
/// and `wattsPerAbsoluteVO2 · VO2max · mass` reads it in watts — the prior, with the
/// filter's own uncertainty plus `levelSD`.
///
/// **W′ is anaerobic.** Every ride proves W′ was *at least* the deficit it ran up at a
/// given CP (`floors`) — a floor, never a measurement, because ordinary training rarely
/// empties the battery.
///
/// **One posterior on a (CP, W′) grid**: prior(CP) × prior(W′) × P(W′ ≥ the binding
/// floor). A ride the prior cannot explain pushes the posterior toward a higher CP *and*
/// a larger W′ at once; a ride far below the prior pushes nothing — watts can prove
/// fitness, not its absence. What this cannot do is bound CP from above with watts:
/// above the prior, only the prior speaks.
///
/// W′ is the **envelope** — the W′ no ride of the athlete overdraws, which is what a
/// floor measures and what a W′ balance needs; a least-squares fit through maximal
/// efforts runs 2–3 kJ below it. Lab reference: `ref/threshold_lab/cycling/cp_wprime.py`;
/// validation on the GoldenCheetah cohort (blinded: CP +0.9 % bias, 4.0 % error; W′
/// −0.6 kJ, 3.2 kJ): `ref/threshold_lab/cycling/FINDINGS.md` §10.
nonisolated enum CriticalPowerEstimate {

    /// Fraction of VO2max held at CP. CP exceeds MLSS by ~5–10 % (Jones et al. 2019) and
    /// sits near 0.80 of VO2max in trained cyclists; 0.821 is athlete-set, and
    /// `VO2maxEstimate.level` is read against exactly this chain, so the two move together.
    static let fractionOfVO2maxAtCP = 0.821
    /// Fraction of VO2max held at FTP.
    static let fractionOfVO2maxAtFTP = 0.76
    /// Gross efficiency of trained cyclists (Jobson review, 18–25 %).
    static let grossEfficiency = 0.22
    /// Watts of metabolic energy per ml O₂/min — Péronnet & Massicotte, mixed substrate.
    static let wattsPerMlOxygenPerMinute = 20.9 / 60
    /// Watts of CP per unit of *absolute* VO2max (ml/kg/min × kg).
    static let wattsPerAbsoluteVO2 = grossEfficiency * fractionOfVO2maxAtCP * wattsPerMlOxygenPerMinute

    /// FTP from CP: the same chain with the threshold's fraction in place of CP's, so
    /// FTP/CP = 0.76/0.821 falls out of the published constants rather than being set.
    static func ftp(cp: Double) -> Double { cp * fractionOfVO2maxAtFTP / fractionOfVO2maxAtCP }

    // MARK: Floors — what one ride proves

    /// Recovery speed: below CP the deficit decays at `k · (CP − P) / W′` per second
    /// (Skiba 2015's model is k = 1). Physiology, for the floors and the displayed balance
    /// alike: ordinary riding on 1047 GoldenCheetah riders lands at 1.2–1.3 once the fit's
    /// artefacts are taken out (FINDINGS §10) — trained cyclists refill a little faster than
    /// Skiba's model (Bartram 2018). A raw fit reads 2.8 because it also absorbs the largest
    /// of many noisy floors standing as proof (`cpDayVariability` carries that instead);
    /// that a lumped constant fits the cohort a little better is no argument for it.
    static let recoveryK = 1.2
    /// The CPs a ride's floor is stored at: 50…700 W in 5 W steps.
    static let floorGridStart = 50.0
    static let floorGridStep = 5.0
    static let floorGridCount = 131
    /// A floor this large rules its CP out whatever the recovery model (W′ grid < 60 kJ).
    static let floorCapJ = 60_000.0
    /// Convergence of the floor's fixed point.
    static let floorToleranceJ = 20.0

    static func gridCP(_ index: Int) -> Double { floorGridStart + floorGridStep * Double(index) }

    /// kJ per grid CP: the smallest W′ whose balance never drops below zero through the
    /// ride, spent 1:1 above CP and refilled at `recoveryK` below it. `power` is the 1 Hz
    /// stream (`WorkoutStreams`), gaps interpolated; `[]` without a reading.
    ///
    /// The floor is the smallest fixed point `W′ = max_t D_t(W′)`; iterating from below
    /// it — the best work above CP over any interval, i.e. instant refill — climbs to it
    /// monotonically, 6–9 rounds on a typical ride.
    static func floors(power bins: [Double?]) -> [Double] {
        let p = oneHertz(bins)
        guard !p.isEmpty else { return [] }
        var out = [Double](repeating: 0, count: floorGridCount)
        for g in 0 ..< floorGridCount {
            let cp = gridCP(g)
            var d = 0.0, w = 0.0
            for x in p { d = max(0, d + x - cp); w = max(w, d) }
            if w > 0, w < floorCapJ {
                for _ in 0 ..< 50 {
                    let peak = peakDeficit(p, cp: cp, wPrimeJ: w)
                    let moved = abs(peak - w) >= floorToleranceJ
                    w = peak
                    if !moved { break }
                }
            }
            out[g] = w / 1000
        }
        return out
    }

    /// kJ: the W′ balance second by second at one (CP, W′), aligned to the stream's bins —
    /// nil before the first and after the last power reading. Below zero is impossible,
    /// so a ride that goes there has proven the (CP, W′) it was read against too low.
    static func balance(power bins: [Double?], cp: Double, wPrimeKJ: Double) -> [Double?] {
        var out = [Double?](repeating: nil, count: bins.count)
        guard let first = bins.firstIndex(where: { $0 != nil }) else { return out }
        let w = wPrimeKJ * 1000, rate = recoveryK / max(w, 500)
        var d = 0.0
        for (i, x) in oneHertz(bins).enumerated() {
            d = x > cp ? d + x - cp : d * exp(rate * (x - cp))
            out[first + i] = (w - d) / 1000
        }
        return out
    }

    /// J: the largest deficit `W′ − balance` through the ride at one (CP, W′).
    private static func peakDeficit(_ p: [Double], cp: Double, wPrimeJ: Double) -> Double {
        let rate = recoveryK / max(wPrimeJ, 500)
        var d = 0.0, peak = 0.0
        for x in p {
            d = x > cp ? d + x - cp : d * exp(rate * (x - cp))
            peak = max(peak, d)
        }
        return peak
    }

    /// 1 Hz bins with gaps filled linearly between the readings around them; the empty
    /// bins before the first and after the last reading are not part of the ride.
    static func oneHertz(_ bins: [Double?]) -> [Double] {
        guard let first = bins.firstIndex(where: { $0 != nil }),
              let last = bins.lastIndex(where: { $0 != nil }) else { return [] }
        var out = [Double](repeating: 0, count: last - first + 1)
        var prev = first
        out[0] = bins[first]!
        for i in (first + 1) ... last {
            guard let v = bins[i] else { continue }
            let a = bins[prev]!
            for k in (prev + 1) ... i {
                out[k - first] = a + (v - a) * Double(k - prev) / Double(i - prev)
            }
            prev = i
        }
        return out
    }

    /// `[kJ,…]` on the floor grid at 10 J, trailing zeros dropped; `""` for no floors.
    static func encode(_ floors: [Double]) -> String {
        var rounded = floors.map { ($0 * 100).rounded() / 100 }
        while rounded.last == 0 { rounded.removeLast() }
        return rounded.isEmpty ? "" : String(compactJSON: rounded)
    }

    /// The floors padded to the full grid, `[]` for none.
    static func decode(_ json: String) -> [Double] {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Double],
              !values.isEmpty, values.count <= floorGridCount else { return [] }
        return values + [Double](repeating: 0, count: floorGridCount - values.count)
    }

    // MARK: The posterior

    /// Between-athlete error of the aerobic level: the filter's leave-one-out |error|
    /// against measured CP is ~4 % (median), a normal sd of ~6 %.
    static let levelSD = 0.06
    /// Triska et al. 2015, field-derived W′ in trained cyclists: 16.3 ± 7.4 kJ, as a
    /// log-normal with that mean and sd.
    static let wPrimeMeanKJ = 16.3
    static let wPrimeSDKJ = 7.4
    static let wPrimeLogSD = log(1 + (wPrimeSDKJ / wPrimeMeanKJ) * (wPrimeSDKJ / wPrimeMeanKJ)).squareRoot()
    static let wPrimeLogMedian = log(wPrimeMeanKJ) - wPrimeLogSD * wPrimeLogSD / 2
    /// Tolerance of a fresh floor: a power meter's ±2 % on a few minutes above CP.
    static let floorSDKJ = 1.5
    /// Day-to-day CP variability: a ride is read at the CP the estimate holds, but the
    /// athlete's CP on that day scatters — test–retest 2–5 %, the GoldenCheetah cohort ~5 %
    /// per 90-day window. It reaches a floor through the floor's slope; without it the
    /// largest of many floors would stand as exact proof.
    static let cpDayVariability = 0.03
    /// How fast the athlete can change, per √week — measured across 1578 GoldenCheetah
    /// riders' dated maximal windows. A floor keeps its value as it ages and its tolerance
    /// widens by these; fading the value instead slid W′ onto the prior between efforts,
    /// 6–8× faster than riders' W′ moves.
    static let cpDriftPerSqrtWeek = 0.011
    static let wPrimeDriftKJPerSqrtWeek = 0.37
    /// How far back floors are read. The largest of more noisy lower bounds sits higher,
    /// so a longer memory lifts CP; below a year W′ steps down as floors leave.
    static let memoryDays = 365.0
    static let cpSpan = 0.7 ... 1.6
    static let wPrimeGrid = (0 ..< 238).map { 0.5 + 0.25 * Double($0) }

    /// One ride's floors (`decode`d).
    struct Ride: Sendable {
        let date: Date
        let floors: [Double]
    }

    struct Estimate: Sendable, Equatable {
        /// The most probable (CP, W′) — watts, kJ — with each one's 80 % interval.
        let cp: Double
        let cpRange: ClosedRange<Double>
        let wPrimeKJ: Double
        let wPrimeRange: ClosedRange<Double>
        /// Rides whose floors the posterior read. Zero means the priors alone answered:
        /// CP is the aerobic estimate, W′ the literature's population value.
        let ridesWithFloors: Int
    }

    /// The (CP, W′) at `date`. `aerobic(date)` is the aerobic CP in watts and its log sd
    /// (nil where the filter has not answered yet).
    ///
    /// **The mode, not the medians.** Where a floor binds, the truth sits on the floor
    /// itself, and a posterior median always lies inside the feasible region — above the
    /// floor on both axes at once (+2.4 % CP, +5.1 kJ W′ on the blinded measured pairs).
    static func estimate(asOf date: Date, rides: [Ride],
                         aerobic: (Date) -> (cp: Double, logSD: Double)?) -> Estimate? {
        guard let prior = aerobic(date) else { return nil }
        let mu = prior.cp
        let s = (prior.logSD * prior.logSD + levelSD * levelSD).squareRoot()
        let cps = Array(stride(from: (cpSpan.lowerBound * mu).rounded(.down),
                               through: (cpSpan.upperBound * mu).rounded(.up), by: 1))
        let ws = wPrimeGrid
        let wPrior = ws.map { -0.5 * pow((log($0) - wPrimeLogMedian) / wPrimeLogSD, 2) - log($0) }

        let earliest = date.addingTimeInterval(-memoryDays * 86_400)
        let past = rides.filter { $0.date <= date && $0.date > earliest && !$0.floors.isEmpty }
        // Every ride is scored against the CP of its own day: its floor is read at
        // `CP × aerobic(ride day) / aerobic(today)`.
        let ratio = past.map { r in aerobic(r.date).map { $0.cp / mu } ?? 1 }
        let weeks = past.map { date.timeIntervalSince($0.date) / (7 * 86_400) }
        let slopes = past.map { gradient($0.floors) }
        let last = Double(floorGridCount - 1)
        let wDrift2 = wPrimeDriftKJPerSqrtWeek * wPrimeDriftKJPerSqrtWeek

        let nW = ws.count
        var logp = [Double](repeating: 0, count: cps.count * nW)
        var frontF: [Double] = [], frontSD: [Double] = []
        for (i, c) in cps.enumerated() {
            let cpPrior = -0.5 * pow((log(c) - log(mu)) / s, 2)
            // The most violated floor at each W′ is one constraint: a product over every
            // ride's floor counts one fact fifty times. Half-Gaussian below, flat above —
            // a floor proves no more. A ride with a lower floor *and* a wider tolerance
            // than another can never be the most violated one, so only the rest are kept.
            frontF.removeAll(keepingCapacity: true)
            frontSD.removeAll(keepingCapacity: true)
            var highest = 0.0
            for r in past.indices {
                let u = min(max((c * ratio[r] - floorGridStart) / floorGridStep, 0), last)
                let k = min(Int(u), floorGridCount - 2), t = u - Double(k)
                let row = past[r].floors, slope = slopes[r]
                let f = row[k] + (row[k + 1] - row[k]) * t
                // CP drift reaches a floor through its slope, the binding interval's length.
                let s = (slope[k] + (slope[k + 1] - slope[k]) * t) * c
                let cpDay = s * cpDayVariability, cpDrift = s * cpDriftPerSqrtWeek
                let sd = (floorSDKJ * floorSDKJ + cpDay * cpDay
                          + weeks[r] * (wDrift2 + cpDrift * cpDrift)).squareRoot()
                guard f > ws[0] else { continue }
                var dominated = false
                for j in frontF.indices where frontF[j] >= f && frontSD[j] <= sd { dominated = true; break }
                if dominated { continue }
                var j = 0
                while j < frontF.count {
                    if f >= frontF[j] && sd <= frontSD[j] {
                        frontF.swapAt(j, frontF.count - 1); frontF.removeLast()
                        frontSD.swapAt(j, frontSD.count - 1); frontSD.removeLast()
                    } else { j += 1 }
                }
                frontF.append(f); frontSD.append(sd)
                highest = max(highest, f)
            }
            for j in 0 ..< nW {
                let w = ws[j]
                var z = 0.0
                if w < highest {
                    for k in frontF.indices where frontF[k] > w { z = max(z, (frontF[k] - w) / frontSD[k]) }
                }
                logp[i * nW + j] = cpPrior + wPrior[j] - 0.5 * z * z
            }
        }

        let top = logp.max() ?? 0
        var cpMarginal = [Double](repeating: 0, count: cps.count)
        var wMarginal = [Double](repeating: 0, count: ws.count)
        var total = 0.0, mode = 0, best = -Double.infinity
        for (k, l) in logp.enumerated() {
            let p = exp(l - top)
            cpMarginal[k / ws.count] += p
            wMarginal[k % ws.count] += p
            total += p
            if l > best { best = l; mode = k }
        }
        func quantile(_ x: [Double], _ pmf: [Double], _ q: Double) -> Double {
            var cdf = [Double](repeating: 0, count: pmf.count), run = 0.0
            for (k, p) in pmf.enumerated() { run += p / total; cdf[k] = run }
            return interpolate(x, cdf, at: q)
        }
        return Estimate(cp: cps[mode / ws.count],
                        cpRange: quantile(cps, cpMarginal, 0.1) ... quantile(cps, cpMarginal, 0.9),
                        wPrimeKJ: ws[mode % ws.count],
                        wPrimeRange: quantile(ws, wMarginal, 0.1) ... quantile(ws, wMarginal, 0.9),
                        ridesWithFloors: past.count)
    }

    /// `y` at `q` on the ascending `xp`, held beyond its ends.
    private static func interpolate(_ y: [Double], _ xp: [Double], at q: Double) -> Double {
        if q <= xp[0] { return y[0] }
        guard let k = xp.firstIndex(where: { $0 > q }) else { return y[y.count - 1] }
        return y[k - 1] + (y[k] - y[k - 1]) * (q - xp[k - 1]) / (xp[k] - xp[k - 1])
    }

    /// kJ per W along the floor grid: central differences inside, one-sided at the ends.
    private static func gradient(_ row: [Double]) -> [Double] {
        let n = row.count, h = floorGridStep
        return (0 ..< n).map { k in
            k == 0 ? (row[1] - row[0]) / h
                : k == n - 1 ? (row[n - 1] - row[n - 2]) / h
                : (row[k + 1] - row[k - 1]) / (2 * h)
        }
    }
}
