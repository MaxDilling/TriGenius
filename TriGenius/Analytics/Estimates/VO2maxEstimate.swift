import Foundation

// MARK: - Cycling VO2max reconstructed from submaximal rides

/// Recovers a cycling VO2max from ordinary riding, for watches that compute none and
/// for athletes who will not ride a maximal test.
///
/// The Åstrand-Ryhming idea with power in place of an ergometer load: convert a
/// sustained effort to its oxygen cost, then scale it up by the heart-rate reserve the
/// athlete left unused. Because `%HRR ≈ %VO2R`, the scaling is against *reserve* rather
/// than against VO2max itself — normalising for resting HR, so the gate tracks the
/// athlete's working range instead of sliding whenever HRmax is corrected.
///
/// Ride readings are noisy — two efforts of one ride agree to ~3 %, two rides of the same
/// week disagree by 5 % (chest strap) to 10 % (wrist) — so VO2max is followed as a slowly
/// moving hidden state (`track`), not selected from the best readings: selecting extremes
/// of ride noise is what made the level jump, ratchet, and collapse when those rides aged
/// out. The lab reference is `ref/threshold_lab/cycling/statespace.py`; derivation and
/// validation on the GoldenCheetah cohort: `ref/threshold_lab/cycling/FINDINGS.md` §9–10.
nonisolated enum VO2maxEstimate {

    /// Durations long enough that anaerobic work capacity no longer decides the mean
    /// power, so the effort reports aerobic cost rather than how much W′ was spent.
    static let durations = [480, 600, 720, 900, 1200, 1800]

    /// ACSM leg ergometry, `VO2 = 1.8 · work(kg·m/min)/mass + 3.5 + 3.5`, with
    /// `1 W = 6.12 kg·m/min`.
    static let acsmSlope = 1.8 * 6.12
    static let acsmBase = 7.0

    /// One MET. The reserve scaling runs on VO2 *above rest*, matching `%HRR`, which is
    /// also measured above rest.
    static let vo2Rest = 3.5

    /// Two efforts of different length from the same ride do not report the same VO2max:
    /// the estimate falls with duration, because heart rate still lags at 8 minutes and
    /// has drifted by 30. Fitted within rides, so ride-to-ride fitness cannot contaminate
    /// the slope. Undoing the fall scales a long effort *up* to the reference — the
    /// exponent is positive.
    static let durationReference = 480.0
    static let durationExponent = 0.080

    /// Heart-rate reserve an effort must sit in (exclusive) to carry aerobic information.
    /// Tightening the lower bound to 0.70 was tried and withdrawn: it scores better only
    /// against self-reported critical powers, which are themselves biased low
    /// (`ref/threshold_lab/cycling/FINDINGS.md`, "GoldenCheetah OpenData").
    static let hrReserveBand = 0.60 ... 0.95

    /// HRmax falls with age — Tanaka 2001's 0.7 bpm/year; the GoldenCheetah cohort's own
    /// yearly ride-peak HR falls 0.64. Held constant, a ride from two years ago reads its
    /// %HRR too high and every later ride's VO2max drifts up with the calendar.
    static let hrMaxDeclinePerYear = 0.7

    // MARK: The filter

    /// Process variance of log VO2max per day: 0.7 %/week (1 sd), the top of the
    /// literature's 0.4–0.7 %/week for trained athletes. Set from physiology, not fitted:
    /// ride readings wander over weeks for reasons that are not fitness (heat, season, a
    /// new sensor), and the likelihood cannot tell that from fitness — it asks for 2 %/week.
    static let processVariancePerDay = 0.007 * 0.007 / 7
    /// The upper expectile of the rides the level tracks. A typical ride sits a different
    /// distance below VO2max for every athlete; the upper expectile carries the level
    /// across athletes, the centre does not.
    static let expectile = 0.9
    /// A shared ride offset that is not fitness — six rides reading high in one week are a
    /// warm week before they are a fitter athlete. It forgets over two weeks; its sd is
    /// the cohort likelihood's at that time.
    static let offsetSD = 0.04
    static let offsetDays = 14.0
    /// Huber threshold on the standardised innovation: a ride with a broken strap moves
    /// the level by a bounded step.
    static let huber = 2.0
    static let minimumRides = 5
    /// Log gap from the filtered level to the VO2max that measured critical powers imply
    /// (`CriticalPowerEstimate.wattsPerAbsoluteVO2`), read on dated 90-day test windows of
    /// the GoldenCheetah cohort. It moves with every constant above, and with
    /// `CriticalPowerEstimate.recoveryK` through which test windows the lab's contradiction
    /// check drops — re-read it in the lab (`statespace.LEVEL`) whenever one changes.
    static let level = 0.051
    /// Bounds on the athlete's ride noise, as log variance: 1–30 % per ride.
    static let rideNoiseBounds = (log(0.01 * 0.01), log(0.30 * 0.30))
    /// Detraining after `idle` days without any session:
    /// `amplitude · (exp(−rhythm/τ) − exp(−idle/τ))`, zero inside the weekly rhythm —
    /// charged from day 3, every ordinary gap drew a dip and a rebound. Fitted on the
    /// cohort's rides after a break; the initial slope, 3.4 %/week, is the literature's
    /// for complete cessation (Coyle 1984).
    static let detrainAmplitude = 0.064
    static let detrainDays = 13.2
    static let rhythmDays = 7.0
    /// A population curve, so its uncertainty is as large as the drift itself: an athlete
    /// who kept training through a riding break reads back up within a few rides.
    static let detrainSD = 1.0
    /// The first weeks the filter answers are it finding a new athlete — `.thin`, counted
    /// from the day it first answers, not from the first session: a sparse runner's fifth
    /// observation can come months after the first.
    static let calibrationDays = 56.0
    /// Beyond this the level rests on no ride newer than a training block.
    static let staleDays = 42.0

    /// One ride's evidence: its best-power/HR profile (`profile`).
    struct Ride: Sendable {
        let date: Date
        let profile: [Int: (watts: Double, hr: Double)]
    }

    /// HRmax on `date`, from a value measured on `measured`, declining with age.
    static func hrMax(_ value: Double, measured: Date, on date: Date) -> Double {
        value - hrMaxDeclinePerYear * date.timeIntervalSince(measured) / (365.25 * 86_400)
    }

    /// One effort as a VO2max reading (ml/kg/min), normalised to `durationReference`;
    /// nil outside the reserve band.
    static func reading(seconds: Int, watts: Double, heartRate: Double,
                        hrMax: Double, hrRest: Double, massKg: Double) -> Double? {
        guard hrMax > hrRest, hrRest > 0, massKg > 0, watts > 0, seconds > 0 else { return nil }
        let hrr = (heartRate - hrRest) / (hrMax - hrRest)
        guard hrr > hrReserveBand.lowerBound, hrr < hrReserveBand.upperBound else { return nil }
        let cost = acsmSlope * watts / massKg + acsmBase
        let full = vo2Rest + (cost - vo2Rest) / hrr
        return full * pow(Double(seconds) / durationReference, durationExponent)
    }

    /// Log VO2max after `idle` days without training has fallen by this much.
    static func detraining(idleDays: Double) -> Double {
        detrainAmplitude * max(0, exp(-rhythmDays / detrainDays) - exp(-idleDays / detrainDays))
    }

    /// The filtered level through an athlete's rides — or runs, for running MAS
    /// (`LTPaceEstimate.track`). A causal filter: the value at a date uses only sessions up
    /// to it, which is what the athlete would have been shown.
    struct Track: Sendable {
        /// Observation times, days since 1970, and the log level and its variance after each.
        let days: [Double]
        let level: [Double]
        let variance: [Double]
        /// Every session of any sport, ascending — idle time counts from the latest.
        let sessions: [Double]
        /// The athlete's noise per observation (log variance), fitted on their own sessions.
        let rideNoise: Double
        /// Log gap added to the filtered level: `VO2maxEstimate.level` for rides, 0 for runs.
        let offset: Double

        /// log VO2max (ml/kg/min) at `date` with its sd, or nil before `minimumRides`.
        func state(at date: Date) -> (log: Double, sd: Double)? {
            let t = VO2maxEstimate.day(date)
            let i = VO2maxEstimate.count(days, atMost: t) - 1
            guard i >= minimumRides - 1 else { return nil }
            let lastSession = sessions[max(VO2maxEstimate.count(sessions, atMost: t) - 1, 0)]
            let drift = detraining(idleDays: t - max(days[i], lastSession))
            let v = variance[i] + processVariancePerDay * (t - days[i]) + (detrainSD * drift) * (detrainSD * drift)
            return (level[i] + offset - drift, v.squareRoot())
        }

        /// The newest observation the level at `date` rests on — what a hand-entered value
        /// is weighed against (`PerformanceHistory`).
        func lastObservation(at date: Date) -> Date? {
            let i = VO2maxEstimate.count(days, atMost: VO2maxEstimate.day(date)) - 1
            return i >= 0 ? Date(timeIntervalSince1970: days[i] * 86_400) : nil
        }

        func confidence(at date: Date) -> EstimateConfidence {
            let t = VO2maxEstimate.day(date)
            let i = max(VO2maxEstimate.count(days, atMost: t) - 1, 0)
            if t - days[minimumRides - 1] < calibrationDays { return .thin }
            return t - days[i] > staleDays ? .stale : .anchored
        }
    }

    /// The filter over every ride, or nil below `minimumRides` rides with a reading.
    ///
    /// One observation per ride — the mean log reading of its gated efforts, which share
    /// that day's heart-rate offset and are one piece of evidence, not six. HRmax is the
    /// athlete's current value, aged to each ride's date; `sessions` are every training
    /// session, any sport, so running through a riding break does not detrain.
    static func track(rides: [Ride], sessions: [Date], hrMax: Double, hrMaxDate: Date,
                      hrRest: Double, massKg: Double) -> Track? {
        let observations = rides.compactMap { ride -> (date: Date, log: Double)? in
            let hm = Self.hrMax(hrMax, measured: hrMaxDate, on: ride.date)
            let logs = durations.compactMap { d in
                ride.profile[d].flatMap {
                    reading(seconds: d, watts: $0.watts, heartRate: $0.hr, hrMax: hm,
                            hrRest: hrRest, massKg: massKg)
                }
            }.map(log)
            return logs.isEmpty ? nil : (ride.date, logs.reduce(0, +) / Double(logs.count))
        }
        return track(observations: observations, sessions: sessions, offset: level)
    }

    /// The filter over one log observation per session, or nil below `minimumRides` of
    /// them. The source supplies only the observations — a ride's mean effort reading, a
    /// run's best MAS — and `offset`; the filter is the same for both.
    static func track(observations: [(date: Date, log: Double)], sessions: [Date],
                      offset: Double) -> Track? {
        let sorted = observations.sorted { $0.date < $1.date }
        let t = sorted.map { day($0.date) }, z = sorted.map(\.log)
        guard z.count >= minimumRides else { return nil }
        let train = Array(Set(t + sessions.map(day))).sorted()
        let drift = t.indices.map { i -> Double in
            guard i > 0 else { return 0 }
            return detraining(idleDays: t[i] - train[max(count(train, below: t[i]) - 1, 0)])
        }
        let noise = exp(minimizeBounded(rideNoiseBounds) { run(t, z, drift, rideNoise: exp($0)).loss })
        let (x, p, _) = run(t, z, drift, rideNoise: noise)
        return Track(days: t, level: x, variance: p, sessions: train, rideNoise: noise, offset: offset)
    }

    /// The Kalman pass: level + offset as a 2×2 covariance `[[a, b], [b, c]]`, an
    /// expectile-weighted Huber update, the Huber negative log-likelihood past
    /// `minimumRides`. `drift[i]` is the detraining charged before ride `i`.
    private static func run(_ t: [Double], _ z: [Double], _ drift: [Double],
                    rideNoise r: Double) -> (level: [Double], variance: [Double], loss: Double) {
        let s2n = offsetSD * offsetSD
        var xs = [Double](repeating: 0, count: z.count), ps = xs
        var x = z[0], n = 0.0, loss = 0.0
        var a = r, b = 0.0, c = s2n
        xs[0] = x; ps[0] = a
        for i in 1 ..< z.count {
            let dt = t[i] - t[i - 1]
            let phi = exp(-dt / offsetDays)
            let d = drift[i]
            x -= d
            a += processVariancePerDay * dt + (detrainSD * d) * (detrainSD * d)
            b *= phi
            c = phi * phi * c + s2n * (1 - phi * phi)
            n *= phi
            let s = a + 2 * b + c + r
            let v = z[i] - x - n
            let u = abs(v) / s.squareRoot()
            if i >= minimumRides {
                loss += 0.5 * log(s) + (u <= huber ? 0.5 * u * u : huber * u - 0.5 * huber * huber)
            }
            let sEff = s - r + (u > huber ? r * u / huber : r) / (2 * (v > 0 ? expectile : 1 - expectile))
            let hx = a + b, hn = b + c
            let kx = hx / sEff, kn = hn / sEff
            x += kx * v
            n += kn * v
            (a, b, c) = (a - kx * hx, b - kx * hn, c - kn * hn)
            xs[i] = x; ps[i] = a
        }
        return (xs, ps, loss)
    }

    private static func day(_ date: Date) -> Double { date.timeIntervalSince1970 / 86_400 }

    /// Elements of ascending `a` that are ≤ `x`.
    private static func count(_ a: [Double], atMost x: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let m = (lo + hi) / 2; if a[m] <= x { lo = m + 1 } else { hi = m } }
        return lo
    }

    /// Elements of ascending `a` that are < `x`.
    private static func count(_ a: [Double], below x: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let m = (lo + hi) / 2; if a[m] < x { lo = m + 1 } else { hi = m } }
        return lo
    }

    /// Brent's bounded minimiser, step for step SciPy's `minimize_scalar(method="bounded")`
    /// at `xatol = 1e-3` — the lab fits the ride noise with it, and the same steps give
    /// the same athlete the same noise here.
    static func minimizeBounded(_ bounds: (Double, Double), xatol: Double = 1e-3,
                                maxIterations: Int = 500, _ f: (Double) -> Double) -> Double {
        let sqrtEps = (2.2e-16).squareRoot(), goldenMean = 0.5 * (3 - 5.0.squareRoot())
        var (a, b) = bounds
        var fulc = a + goldenMean * (b - a)
        var nfc = fulc, xf = fulc
        var rat = 0.0, e = 0.0
        var fx = f(xf)
        var num = 1
        var ffulc = fx, fnfc = fx
        var xm = 0.5 * (a + b)
        var tol1 = sqrtEps * abs(xf) + xatol / 3, tol2 = 2 * tol1
        while abs(xf - xm) > tol2 - 0.5 * (b - a) {
            var golden = true
            if abs(e) > tol1 {
                golden = false
                var r = (xf - nfc) * (fx - ffulc)
                var q = (xf - fulc) * (fx - fnfc)
                var p = (xf - fulc) * q - (xf - nfc) * r
                q = 2 * (q - r)
                if q > 0 { p = -p }
                q = abs(q)
                r = e
                e = rat
                if abs(p) < abs(0.5 * q * r), p > q * (a - xf), p < q * (b - xf) {
                    rat = p / q
                    let x = xf + rat
                    if x - a < tol2 || b - x < tol2 {
                        rat = xm - xf >= 0 ? tol1 : -tol1
                    }
                } else {
                    golden = true
                }
            }
            if golden {
                e = xf >= xm ? a - xf : b - xf
                rat = goldenMean * e
            }
            let x = xf + (rat >= 0 ? 1 : -1) * max(abs(rat), tol1)
            let fu = f(x)
            num += 1
            if fu <= fx {
                if x >= xf { a = xf } else { b = xf }
                (fulc, ffulc) = (nfc, fnfc)
                (nfc, fnfc) = (xf, fx)
                (xf, fx) = (x, fu)
            } else {
                if x < xf { a = x } else { b = x }
                if fu <= fnfc || nfc == xf {
                    (fulc, ffulc) = (nfc, fnfc)
                    (nfc, fnfc) = (x, fu)
                } else if fu <= ffulc || fulc == xf || fulc == nfc {
                    (fulc, ffulc) = (x, fu)
                }
            }
            xm = 0.5 * (a + b)
            tol1 = sqrtEps * abs(xf) + xatol / 3
            tol2 = 2 * tol1
            if num >= maxIterations { break }
        }
        return xf
    }

    // MARK: Running

    /// ACSM horizontal running / Daniels, `VO2 = 0.2 · v(m/min) + 3.5`.
    ///
    /// The vertical term is deliberately absent: `LTPaceEstimate` reconstructs MAS from
    /// **grade-adjusted** speed, so the hill is already priced into v, and adding
    /// `0.9 · v · grade` on top would charge for it twice.
    static let acsmRunSlope = 0.2

    /// Running VO2max (ml/kg/min) from reconstructed maximal aerobic speed.
    ///
    /// Not a second estimator: MAS *is* a VO2max in speed units — `LTPaceEstimate`
    /// scales grade-adjusted speed by the unused heart-rate reserve, which is the
    /// `%VO2R` scaling below expressed in m/s (the rest term cancels, because the
    /// running equation's base *is* `vo2Rest`). This only changes the unit, so the run
    /// threshold and the run VO2max can never describe two different athletes.
    ///
    /// Derivation: `ref/threshold_lab/running/FINDINGS.md` §4.6.
    static func running(mas: Double) -> Double? {
        guard mas > 0 else { return nil }
        return acsmRunSlope * mas * 60 + vo2Rest
    }

    // MARK: Per-activity evidence

    /// Best mean power over each duration, paired with the heart rate held across those
    /// same seconds.
    ///
    /// Stored per ride rather than a finished VO2max, because the reconstruction needs
    /// HRmax, HRrest and mass and those are read-time values — keeping the pair lets a
    /// corrected HRmax re-resolve the whole history without re-ingesting. Both streams
    /// are the ones the sources already shape for zone bucketing.
    static func profile(power: [NormalizedStream.Sample],
                        heartRate: [NormalizedStream.Sample]) -> [Int: (watts: Double, hr: Double)] {
        let watts = expand(power), hr = expand(heartRate)
        let usable = min(watts.count, hr.count)
        guard usable >= durations[0] else { return [:] }

        var powerSum: [Double] = [0], hrSum: [Double] = [0]
        powerSum.reserveCapacity(usable + 1); hrSum.reserveCapacity(usable + 1)
        for i in 0 ..< usable {
            powerSum.append(powerSum[i] + watts[i])
            hrSum.append(hrSum[i] + hr[i])
        }

        var out: [Int: (watts: Double, hr: Double)] = [:]
        for d in durations where usable >= d {
            var bestStart = 0, bestTotal = -1.0
            for start in 0 ... (usable - d) {
                let total = powerSum[start + d] - powerSum[start]
                if total > bestTotal { bestTotal = total; bestStart = start }
            }
            let meanHR = (hrSum[bestStart + d] - hrSum[bestStart]) / Double(d)
            guard bestTotal > 0, meanHR > 0 else { continue }
            out[d] = (bestTotal / Double(d), meanHR)
        }
        return out
    }

    /// Expand to 1 Hz, pairing the two streams by elapsed second — a stop has to keep
    /// consuming time in both or they slide apart.
    private static func expand(_ samples: [NormalizedStream.Sample]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(samples.count)
        for s in samples {
            let seconds = min(max(Int(s.seconds.rounded()), 1), 30)
            for _ in 0 ..< seconds { out.append(s.value) }
        }
        return out
    }

    /// `[[seconds,watts,bpm],…]` ascending; `""` for no profile.
    static func encode(_ profile: [Int: (watts: Double, hr: Double)]) -> String {
        guard !profile.isEmpty else { return "" }
        let pairs: [[Any]] = profile.keys.sorted().map {
            [$0, (profile[$0]!.watts * 10).rounded() / 10, (profile[$0]!.hr * 10).rounded() / 10]
        }
        return String(compactJSON: pairs)
    }

    static func decode(_ json: String) -> [Int: (watts: Double, hr: Double)] {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[Double]]
        else { return [:] }
        var out: [Int: (watts: Double, hr: Double)] = [:]
        for row in rows where row.count == 3 { out[Int(row[0])] = (row[1], row[2]) }
        return out
    }
}
