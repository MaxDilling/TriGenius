import Foundation

// MARK: - Running MAS, LT pace and running VO2max from ordinary runs

/// Recovers a running lactate-threshold pace without a benchmark effort, for watches that
/// report none and for athletes who cannot safely produce one — in eight months of real
/// training only one of 37 runs held such an effort.
///
/// The frame is the one the literature converges on (`LT = LT% x MAS`, r = 0.95, SEE
/// 4.0 %): maximal aerobic speed carries the signal. MAS is reconstructed from *easy*
/// running by scaling grade-adjusted speed with the unused heart-rate reserve, which cancels
/// the athlete's running economy instead of assuming a population value for it.
///
/// Each run is one observation — its best settled in-band reconstruction — followed as the
/// same hidden state the cycling VO2max is (`VO2maxEstimate.track`), not reduced by a
/// quantile over a window: a window of a low-volume athlete's runs swung ±20 s/km on its
/// composition alone and went silent whenever it thinned out.
///
/// Derivation and validation: `ref/threshold_lab/running/FINDINGS.md` §8.
nonisolated enum LTPaceEstimate {

    /// LT speed as a fraction of reconstructed MAS: the share of heart-rate reserve held at
    /// threshold, which is `%HRR` at LTHR. **A property of the athlete** — 0.818 and 0.886
    /// on the two reference athletes, over the last 20 minutes of a 30-minute threshold
    /// test, the window LTHR is read over.
    ///
    /// No level constant divides it: the filtered MAS measured 1.052 and 1.002 of the MAS
    /// each athlete held in that test, and two athletes cannot tell the mean from 1.
    static func fractionOfMAS(lthr: Double, hrRest: Double, hrMax: Double) -> Double? {
        guard hrMax > hrRest, hrRest > 0, lthr > hrRest, lthr <= hrMax else { return nil }
        return (lthr - hrRest) / (hrMax - hrRest)
    }

    /// A block whose heart rate is still climbing has not caught up with the effort, so the
    /// reserve it appears to leave unused is overstated and the reconstruction reads high.
    static let maxDriftBpmPerMinute = 2.0

    /// The value is published on a grid this many seconds per km wide — the resolution
    /// the pace is displayed at, and nothing more. Suppressing an unearned change needs
    /// the filter, not a coarse grid on the level.
    static let paceGridSeconds = 1.0

    /// Heart rate lags a change in effort, so the opening minutes carry a speed that
    /// the heart rate does not yet describe.
    static let warmUpSeconds = 600

    /// One minute is long enough for heart rate to have caught up with the effort and
    /// short enough that a varied run still yields many usable points.
    static let blockSeconds = 60

    /// Minutes a run must last past the warm-up before it says anything about MAS. Shorter,
    /// and its "best" block is whichever few minutes happened to be quickest — on a real
    /// season a 14.8-minute run held the highest MAS of the whole dataset.
    static let minimumBlocks = 6

    /// In-band heart-rate buckets a run needs to be an observation. Chosen on next-run
    /// prediction in the lab: lowest at 2 on both reference athletes, and from 3 on the
    /// low-volume one has too few runs left to be scored at all.
    static let minimumBuckets = 2

    /// Fractions of HRmax a block must sit between. Below the floor the HR-speed
    /// relation bends and easy running dominates; above the ceiling the reserve
    /// scaling saturates.
    static let hrBand = 0.80 ... 0.95

    /// A block with any real stop in it is not one effort.
    static let minMovingFraction = 0.95
    static let movingSpeedMps = 0.5
    static let minBlockSpeedMps = 1.2

    // MARK: Per-activity evidence

    /// The run's heart rate → best grade-adjusted speed profile, 1 bpm resolution.
    ///
    /// Stored per activity rather than a finished MAS, because MAS needs HRmax and
    /// HRrest and those are read-time values: keeping the profile lets a corrected
    /// HRmax re-resolve the whole history without re-ingesting it. Only the fastest
    /// block per bpm can ever win the maximum at read time, so keeping just that one
    /// is lossless for what the profile is used for.
    ///
    /// Both streams are the ones the sources already shape for zone bucketing —
    /// `ZoneMetric.pace` is grade-adjusted speed, so hills are already removed.
    static func profile(gradeAdjustedSpeed: [NormalizedStream.Sample],
                        heartRate: [NormalizedStream.Sample]) -> [Int: Double] {
        let speed = expand(gradeAdjustedSpeed), hr = expand(heartRate)
        let usable = min(speed.count, hr.count)
        guard usable >= warmUpSeconds + minimumBlocks * blockSeconds else { return [:] }

        let n = Double(blockSeconds)
        let centre = (n - 1) / 2
        var xVariance = 0.0
        for i in 0 ..< blockSeconds { xVariance += (Double(i) - centre) * (Double(i) - centre) }

        var best: [Int: Double] = [:]
        var start = warmUpSeconds
        while start + blockSeconds <= usable {
            var speedSum = 0.0, hrSum = 0.0, drift = 0.0, moving = 0
            for i in start ..< (start + blockSeconds) {
                speedSum += speed[i]
                hrSum += hr[i]
                drift += (Double(i - start) - centre) * hr[i]
                if speed[i] > movingSpeedMps { moving += 1 }
            }
            start += blockSeconds
            guard Double(moving) / Double(blockSeconds) > minMovingFraction else { continue }
            let meanSpeed = speedSum / n
            let meanHR = hrSum / n
            guard meanSpeed >= minBlockSpeedMps, meanHR > 0,
                  drift / xVariance * 60 <= maxDriftBpmPerMinute else { continue }
            let bpm = Int(meanHR.rounded())
            if meanSpeed > best[bpm] ?? 0 { best[bpm] = meanSpeed }
        }
        return best
    }

    /// Expand to 1 Hz. Unlike the LTHR windows this must NOT drop zero samples: the
    /// two streams are paired by elapsed second, so a stop has to keep consuming time
    /// in both or they slide apart.
    private static func expand(_ samples: [NormalizedStream.Sample]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(samples.count)
        for s in samples {
            // A single reading standing for an implausible span is a recording gap,
            // not a held value; clamp so it cannot dominate a block.
            let seconds = min(max(Int(s.seconds.rounded()), 1), 30)
            for _ in 0 ..< seconds { out.append(s.value) }
        }
        return out
    }

    // MARK: `paceHRProfileJSON` codec

    /// `[[bpm,speed],…]` ascending, m/s to 0.001; `""` for no profile.
    static func encode(_ profile: [Int: Double]) -> String {
        guard !profile.isEmpty else { return "" }
        let pairs: [[Any]] = profile.keys.sorted().map { [$0, (profile[$0]! * 1000).rounded() / 1000] }
        return String(compactJSON: pairs)
    }

    static func decode(_ json: String) -> [Int: Double] {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let pairs = try? JSONSerialization.jsonObject(with: data) as? [[Double]]
        else { return [:] }
        var profile: [Int: Double] = [:]
        for pair in pairs where pair.count == 2 { profile[Int(pair[0])] = pair[1] }
        return profile
    }

    // MARK: Read time

    /// One run's MAS observation (m/s): its fastest in-band bucket, reconstructed as
    /// `MAS = v / %HRR` — with `%HRR ≈ %VO2R` and `VO2 = CR·v + VO2rest` the cost of running
    /// cancels, so the athlete's own economy is folded in without being measured. Nil when
    /// fewer than `minimumBuckets` buckets sit in the band. `hrMax` is the one of the run's date.
    static func reading(profile: [Int: Double], hrMax: Double, hrRest: Double) -> Double? {
        guard hrMax > hrRest, hrRest > 0 else { return nil }
        let inBand = profile.compactMap { bpm, speed -> Double? in
            let hr = Double(bpm)
            guard hr >= hrBand.lowerBound * hrMax, hr <= hrBand.upperBound * hrMax, hr > hrRest
            else { return nil }
            return speed * (hrMax - hrRest) / (hr - hrRest)
        }
        return inBand.count >= minimumBuckets ? inBand.max() : nil
    }

    /// One run's evidence: its heart rate → best grade-adjusted speed profile.
    struct Run: Sendable {
        let date: Date
        let profile: [Int: Double]
    }

    /// Reconstructed MAS as a filtered state (`VO2maxEstimate.track`, offset 0), or nil below
    /// its `minimumRides` observations. HRmax is the athlete's current value aged to each
    /// run's date; `sessions` are every training session of any sport, so a bike block does
    /// not read as detraining.
    ///
    /// MAS, not LT speed: two thresholds read it — LT pace through
    /// `ltSpeed(mas:fractionOfMAS:)` and running VO2max through `VO2maxEstimate.running(mas:)`
    /// — so the two can never describe different athletes.
    static func track(runs: [Run], sessions: [Date], hrMax: Double, hrMaxDate: Date,
                      hrRest: Double) -> VO2maxEstimate.Track? {
        let observations = runs.compactMap { run -> (date: Date, log: Double)? in
            reading(profile: run.profile,
                    hrMax: VO2maxEstimate.hrMax(hrMax, measured: hrMaxDate, on: run.date),
                    hrRest: hrRest).map { (run.date, log($0)) }
        }
        return VO2maxEstimate.track(observations: observations, sessions: sessions, offset: 0)
    }

    /// LT speed (m/s) — the athlete's share of reconstructed MAS, on the published grid.
    static func ltSpeed(mas: Double, fractionOfMAS: Double) -> Double? {
        guard mas > 0, fractionOfMAS > 0 else { return nil }
        let paceSeconds = (1000 / (mas * fractionOfMAS) / paceGridSeconds).rounded() * paceGridSeconds
        return paceSeconds > 0 ? 1000 / paceSeconds : nil
    }
}
