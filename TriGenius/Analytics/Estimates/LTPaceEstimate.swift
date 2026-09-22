import Foundation

// MARK: - Running LT pace estimated from ordinary runs

/// Recovers a running lactate-threshold pace without a benchmark effort, for
/// watches that report none and for athletes who cannot safely produce one — a
/// maximal 20-minute run is the session that injures the tendon- and bone-limited
/// athlete this app is built for, and in eight months of real training only one of
/// 37 runs held such an effort.
///
/// The frame is the one the literature converges on (`LT = LT% x MAS`, r = 0.95,
/// SEE 4.0 %): maximal aerobic speed carries the signal. MAS is reconstructed from
/// *easy* running by scaling grade-adjusted speed with the unused heart-rate reserve,
/// which cancels the athlete's running economy instead of assuming a population value
/// for it — the term that otherwise separates two athletes with the same VO2max. The
/// threshold fraction is **not** a population constant; see `fractionOfMAS`.
///
/// Derivation, the rejected markers and the validation limits:
/// `ref/threshold_lab/running/FINDINGS.md`.
nonisolated enum LTPaceEstimate {

    /// How far the aggregate sits above the MAS an athlete actually shows in a threshold
    /// effort. Fixed for the aggregation, unlike the fraction below: measured at 1.03–1.04
    /// on two athletes who differ by 8.4 % in the fraction itself.
    static let poolInflation = 1.035

    /// LT speed as a fraction of reconstructed MAS.
    ///
    /// **This is a property of the athlete, not a population constant**, and getting that
    /// wrong is what a single shared value cost: it is the fraction of heart-rate reserve
    /// the athlete holds at threshold, divided by `poolInflation`. On the two reference
    /// athletes that fraction is 0.799 and 0.869 — 8.4 % apart, worth 21 s/km on the one
    /// whose heart rate is capped, and in the direction that over-prescribes. A shared
    /// constant happened to fit one of them and looked validated on the other only because
    /// two errors cancelled.
    ///
    /// Derived from the athlete's own LTHR rather than asked for, since all three inputs
    /// are already known; the setting is an override for an athlete who has measured it in
    /// a threshold test.
    static func fractionOfMAS(lthr: Double, hrRest: Double, hrMax: Double) -> Double? {
        guard hrMax > hrRest, hrRest > 0, lthr > hrRest, lthr <= hrMax else { return nil }
        return (lthr - hrRest) / (hrMax - hrRest) / poolInflation
    }

    /// Quantile over each run's best reconstruction. A rolling maximum reads whatever the
    /// single hardest minute of the window was; the median reads the athlete's easy running.
    static let runQuantile = 0.75

    /// A block whose heart rate is still climbing has not caught up with the effort, so
    /// the reserve it appears to leave unused is overstated and the reconstruction reads
    /// high. Admitting only settled blocks is what makes the fraction above mean what it
    /// says instead of silently absorbing the lag.
    static let maxDriftBpmPerMinute = 2.0

    /// The value is published on a grid this many seconds per km wide — the resolution
    /// the pace is displayed at, and nothing more.
    ///
    /// It deliberately no longer stands in for the smallest worthwhile change. That is
    /// ~1.5-2 % of a threshold (Hopkins; LT-velocity CV 1.5-2.8 %, Zanini 2025), which
    /// here is 4-6 s/km — but quantising to it is not the same instrument: a value
    /// sitting on a cell boundary flips the full cell width on sub-noise movement,
    /// which is the artifact a change threshold exists to prevent. Suppressing an
    /// unearned change needs hysteresis on the change, not a coarse grid on the level.
    static let paceGridSeconds = 1.0

    /// Heart rate lags a change in effort, so the opening minutes carry a speed that
    /// the heart rate does not yet describe.
    static let warmUpSeconds = 600

    /// One minute is long enough for heart rate to have caught up with the effort and
    /// short enough that a varied run still yields many usable points.
    static let blockSeconds = 60

    /// Settled minutes a run must hold before it says anything about MAS. Fewer, and
    /// the run's "best" block is whichever of two or three minutes happened to be
    /// quickest — on a real season a 14.8-minute run produced the highest MAS of the
    /// whole dataset off four blocks, and it decided the estimate for two months.
    static let minimumBlocks = 6

    /// Fractions of HRmax a block must sit between. Below the floor the HR-speed
    /// relation bends and easy running dominates; above the ceiling the reserve
    /// scaling saturates.
    static let hrBand = 0.80 ... 0.95

    /// A block with any real stop in it is not one effort.
    static let minMovingFraction = 0.95
    static let movingSpeedMps = 0.5
    static let minBlockSpeedMps = 1.2

    /// How far back runs are gathered, and how many must qualify before a window is
    /// trusted. Below roughly seven the estimate swings ~20 s/km on window
    /// composition alone, which is larger than anything it is meant to measure.
    static let historyDays = 90
    /// Below this a window is not answered at all and the last one that was gets carried
    /// forward, so the gate decides how much of the series is measurement rather than
    /// memory. At seven it answered on **17 %** of fortnightly dates for a real
    /// low-volume athlete — the rest of his curve was carry-forward wearing the same
    /// styling as a reading. Three is what `ref/threshold_lab/running` answers on, and
    /// it reaches 58 %: a window this thin swings ±20 s/km on its own, but a carried
    /// value is not steadier, it is only quieter about it — and it is now drawn as the
    /// memory it is, which is what makes the thinner gate the honest trade.
    ///
    /// Widening `historyDays` instead does not work — it moves the pool, and the
    /// inflation the fraction divides by is calibrated on a 90-day pool. At 180 days the
    /// second reference athlete lands 19 s/km off her own field test.
    static let minimumRuns = 3

    /// At or above this the aggregate is a robust one; below it the window still
    /// answers — it is the best evidence there is — but the answer is reported as
    /// `.thin`, because it is one or two sessions wearing a quantile's clothes.
    ///
    /// The p75 index is `0.75 x (n - 1)`, so at n = 5 and n = 9 it is a whole number and
    /// the "quantile" is literally one run. On a real January pool, appending a single
    /// run at the **top** — nothing existing got faster, nothing aged out — took the
    /// index from 2.25 to 3.00 and the answer from 5:21 to 4:57 /km. Raising
    /// `minimumRuns` does not fix that (at 5 and 6 the largest nine-day step is *worse*,
    /// 28-29 s/km); seven is where it halves, which is the same seven
    /// `ref/threshold_lab/running` measures the ~20 s/km window-composition swing below.
    static let anchoredRuns = 7

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

    /// Every maximal-aerobic-speed reading (m/s) one run's profile carries — one per
    /// in-band heart-rate bucket, not just the run's best.
    ///
    /// `%HRR ~ %VO2R` with `VO2 = CR*v + VO2rest` makes the cost of running cancel:
    /// `MAS = v / f`. That cancellation is the point — the athlete's own economy is
    /// folded in without being measured. Empty when no bucket sits in the band.
    ///
    /// Returning all of them is what lets the estimate rest on a few hundred readings
    /// rather than one per run: a quantile over a dozen sessions moves whenever any
    /// one of them enters or ages out, and a drill session counts the same as a race.
    static func aerobicSpeeds(profile: [Int: Double], hrMax: Double, hrRest: Double) -> [Double] {
        guard hrMax > hrRest, hrRest > 0 else { return [] }
        let reserve = hrMax - hrRest
        return profile.compactMap { bpm, speed in
            let hr = Double(bpm)
            guard hr >= hrBand.lowerBound * hrMax, hr <= hrBand.upperBound * hrMax, hr > hrRest
            else { return nil }
            return speed * reserve / (hr - hrRest)
        }
    }

    /// Reconstructed maximal aerobic speed (m/s) from the per-run reconstructions, or
    /// nil when no window ever held enough of them.
    ///
    /// MAS, not LT speed: it is what the pool actually measures, and **two thresholds
    /// read it** — LT pace through `ltSpeed(mas:fractionOfMAS:)` and running VO2max
    /// through `VO2maxEstimate.running(mas:)`, which is this same number under the ACSM
    /// economy equation. One aggregation, so the two can never disagree about the
    /// athlete.
    ///
    /// A window that still holds `minimumRuns` answers directly. Otherwise the most
    /// recent window that did is carried forward unchanged — the estimate is a rolling
    /// high quantile, so it does not fall as evidence ages out, it simply stops
    /// existing, and a stale threshold silently drops TL scoring. It is held rather
    /// than decayed for detraining: the decay was a second model layered on a value
    /// that already has no evidence behind it, worth 9.7 % (~30 s/km) of movement no
    /// run ever showed. `confidence` says it is memory; the chart draws it as memory.
    struct Estimate: Sendable, Equatable {
        let masMps: Double
        let confidence: EstimateConfidence
        let runCount: Int
    }

    static func estimate(runs: [(date: Date, speeds: [Double])], asOf: Date) -> Estimate? {
        let usable = runs.filter { !$0.speeds.isEmpty && $0.date <= asOf }.sorted { $0.date < $1.date }
        guard !usable.isEmpty else { return nil }
        if let current = windowed(usable, endingAt: asOf) {
            return Estimate(masMps: current.speed,
                            confidence: current.runs >= anchoredRuns ? .anchored : .thin,
                            runCount: current.runs)
        }
        // Carried forward. This is the common case for a low-volume athlete, so it has
        // to be reported as memory rather than measurement — the value alone cannot say
        // which it is.
        for run in usable.reversed() {
            guard let held = windowed(usable, endingAt: run.date) else { continue }
            return Estimate(masMps: held.speed, confidence: .stale, runCount: 0)
        }
        return nil
    }

    /// LT speed (m/s) — the athlete's share of reconstructed MAS, on the published grid.
    static func ltSpeed(mas: Double, fractionOfMAS: Double) -> Double? {
        guard mas > 0, fractionOfMAS > 0 else { return nil }
        return onGrid(mas * fractionOfMAS)
    }

    /// Reconstructed MAS over the `historyDays` ending at `end`, or nil below
    /// `minimumRuns`.
    ///
    /// Each run contributes its own best reconstruction and the quantile runs across
    /// runs, so a long session cannot outvote a short one by sheer bucket count — the
    /// unit of evidence is the session, which is also what the gate counts.
    private static func windowed(_ runs: [(date: Date, speeds: [Double])],
                                 endingAt end: Date) -> (speed: Double, runs: Int)? {
        let cutoff = end.addingTimeInterval(-Double(historyDays) * 86_400)
        let perRun = runs.filter { $0.date > cutoff && $0.date <= end }
            .compactMap { $0.speeds.max() }
        guard perRun.count >= minimumRuns else { return nil }
        return (quantile(perRun, runQuantile), perRun.count)
    }

    /// Linear-interpolated quantile of an unsorted sample.
    private static func quantile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        let position = q * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    /// Snap to the published pace grid, so the value only moves when the movement
    /// means something.
    private static func onGrid(_ speedMps: Double) -> Double {
        guard speedMps > 0 else { return speedMps }
        let paceSeconds = (1000 / speedMps / paceGridSeconds).rounded() * paceGridSeconds
        return paceSeconds > 0 ? 1000 / paceSeconds : speedMps
    }

}
