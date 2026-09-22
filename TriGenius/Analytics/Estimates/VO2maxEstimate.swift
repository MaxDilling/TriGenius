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
/// Derivation, the rejected aggregations and the validation limits:
/// `ref/threshold_lab/cycling/FINDINGS.md`.
nonisolated enum VO2maxEstimate {

    /// One sustained effort: the best mean power over `seconds`, and the mean heart rate
    /// held across those same seconds.
    struct Effort: Sendable, Equatable {
        let date: Date
        let seconds: Int
        let watts: Double
        let heartRate: Double

        init(date: Date, seconds: Int, watts: Double, heartRate: Double) {
            self.date = date; self.seconds = seconds
            self.watts = watts; self.heartRate = heartRate
        }
    }

    struct Estimate: Sendable, Equatable {
        let vo2max: Double
        let confidence: EstimateConfidence
        let effortCount: Int
        let evidenceAgeDays: Double
    }

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
    /// the slope. Without it every aggregate is decided by the shortest bin.
    static let durationReference = 480.0
    static let durationExponent = 0.080

    /// Heart-rate reserve an effort must sit in to carry aerobic information. The band is
    /// wide on purpose — it is what lets a central statistic replace a maximum, admitting
    /// several hundred efforts per athlete instead of a few dozen.
    ///
    /// Tightening the lower bound to 0.70 was tried and withdrawn: it scores better
    /// against self-reported critical powers only because those are themselves biased
    /// low, and it makes the estimate fall below the floor the athlete's own efforts
    /// prove. `ref/threshold_lab/cycling/FINDINGS.md`, "GoldenCheetah OpenData".
    static let hrReserveBand = 0.60 ... 0.95

    /// Aggregate the best `topEfforts`, not a quantile over all of them. A quantile is a
    /// quantile over how much easy riding happened lately; selecting by *value* makes
    /// added easy volume inert, while the age kernel still lets the number fall as good
    /// efforts get old. The count is absolute and must stay absolute — a fraction of the
    /// pool would grow with volume and reintroduce exactly that dilution, and tests
    /// against measured critical powers show a fraction is a reparameterisation and
    /// nothing more.
    ///
    /// Ten and not twenty: against riders whose own maximal efforts identify a critical
    /// power, the truth sits at the 99th percentile of the effort pool and twenty reads
    /// the 96th. Ten also halves a structural bias — a thin pool forces the operator
    /// further down its own distribution, so an athlete with few efforts reads low.
    ///
    /// Keeping this below `minimumEfforts` is load-bearing: at equal values an athlete
    /// at the minimum would get no selection at all, and the aggregate would silently
    /// become a plain mean while still reporting itself as anchored.
    static let topEfforts = 10
    static let minimumEfforts = 20
    static let ageTauDays = 90.0

    /// Beyond this the estimate rests on evidence older than a training block and stops
    /// describing the present.
    static let staleDays = 42.0

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
    /// Derivation: `ref/threshold_lab/running/vo2max.py`.
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

    // MARK: Read time

    /// Every gated effort as a VO2max reading, normalised to `durationReference`.
    ///
    /// One reading per (ride, duration) rather than per ride: a ride-level maximum throws
    /// away five sixths of the evidence and always keeps the shortest, most HR-lagged bin.
    static func readings(efforts: [Effort], hrMax: Double, hrRest: Double,
                         massKg: Double) -> [(date: Date, vo2max: Double)] {
        guard hrMax > hrRest, hrRest > 0, massKg > 0 else { return [] }
        let reserve = hrMax - hrRest
        return efforts.compactMap { e in
            guard e.watts > 0, e.seconds > 0 else { return nil }
            let hrr = (e.heartRate - hrRest) / reserve
            guard hrReserveBand.contains(hrr) else { return nil }
            let cost = acsmSlope * e.watts / massKg + acsmBase
            let full = vo2Rest + (cost - vo2Rest) / hrr
            return (e.date, full * pow(Double(e.seconds) / durationReference, -durationExponent))
        }
    }

    /// VO2max (ml/kg/min) with the confidence it carries, or nil below `minimumEfforts`.
    static func estimate(efforts: [Effort], hrMax: Double, hrRest: Double,
                         massKg: Double, asOf: Date) -> Estimate? {
        let pool = readings(efforts: efforts.filter { $0.date <= asOf },
                            hrMax: hrMax, hrRest: hrRest, massKg: massKg)
        guard pool.count >= minimumEfforts else { return nil }

        let best = pool.sorted { $0.vo2max > $1.vo2max }.prefix(topEfforts)
        let ages = best.map { asOf.timeIntervalSince($0.date) / 86_400 }
        let weights = ages.map { RecencyWeighting.weight(ageDays: $0, tauDays: ageTauDays) }
        let total: Double = weights.reduce(0, +)
        guard total > 0 else { return nil }
        var weighted = 0.0
        for (reading, weight) in zip(best, weights) { weighted += reading.vo2max * weight }
        let value = weighted / total

        let freshest = ages.min() ?? .infinity
        return Estimate(vo2max: value,
                        confidence: freshest > staleDays ? .stale : .anchored,
                        effortCount: pool.count, evidenceAgeDays: freshest)
    }
}
