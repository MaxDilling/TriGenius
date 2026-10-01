import Testing
import Foundation
@testable import TriGenius

// Pins `PerformanceHistory.estimatedSeries` — the progression of a threshold that
// has no stored series of its own (`CriticalPowerEstimate` / `LTHREstimate`), re-resolved at
// every date one of its inputs moved. Dates are relative to now because the
// resolver anchors the LTHR observation window on today.
struct PerformanceHistoryTests {

    private let now = Date()

    /// `days` ago.
    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func entry(_ date: Date, _ value: Double, rank: Int = 2) -> PerformanceHistory.Entry {
        .init(date: date, value: value, rank: rank)
    }

    // MARK: Cycling VO2max, CP/W′ and FTP

    /// Eight rides with power and heart rate, a floor from a hard 5-minute effort on each.
    private var rides: [PerformanceHistory.ActivityEvidence] {
        let floors = CriticalPowerEstimate.floors(power: [Double](repeating: 150, count: 600)
            + [Double](repeating: 350, count: 300) + [Double](repeating: 150, count: 600))
        return (0 ..< 8).map { k in
            .init(date: ago(Double(40 - 4 * k)), steadyHR20: 0, peakHR: 180,
                  submaxProfile: [480: (watts: 240 + Double(k % 3) * 10, hr: 152),
                                  1200: (watts: 225, hr: 156)],
                  wPrimeFloors: floors, family: .bike)
        }
    }

    private func cycling(ftp: Bool = true, cp: Bool = true, vo2: Bool = false,
                         extra: [String: [PerformanceHistory.Entry]] = [:]) -> PerformanceHistory {
        PerformanceHistory(
            byKey: ["max_hr": [entry(ago(100), 190)], "resting_hr": [entry(ago(100), 50)],
                    "weight_kg": [entry(ago(100), 70)]].merging(extra) { $1 },
            estimateFTPFromCP: ftp, estimateVO2maxFromRides: vo2, estimateCPFromRides: cp,
            evidence: rides)
    }

    /// FTP is the joint CP times 0.76 / 0.821 — one posterior, so the two cannot disagree.
    @Test func ftpIsDerivedFromTheJointCP() throws {
        let snap = cycling().snapshot(asOf: now)
        let cp = try #require(snap.criticalPower)
        #expect(snap.criticalPowerIsEstimated && snap.wPrimeIsEstimated && snap.cyclingFTPIsEstimated)
        #expect(snap.cyclingFTP == Int(CriticalPowerEstimate.ftp(cp: cp).rounded()))
        #expect(snap.criticalPowerRange!.contains(cp))
        // The rides are 4-40 days old: still inside the 8-week calibration.
        #expect(snap.criticalPowerConfidence == .thin)
    }

    /// Rides without floors (stored before floors existed, not yet recomputed) leave the
    /// priors alone — which must not read as a value backed by recent efforts.
    @Test func withoutAnyFloorCPAndWPrimeAreRough() {
        let bare = rides.map {
            PerformanceHistory.ActivityEvidence(date: $0.date, steadyHR20: 0, peakHR: $0.peakHR,
                                                submaxProfile: $0.submaxProfile, family: .bike)
        }
        let snap = PerformanceHistory(
            byKey: ["max_hr": [entry(ago(100), 190)], "resting_hr": [entry(ago(100), 50)],
                    "weight_kg": [entry(ago(100), 70)]],
            estimateFTPFromCP: true, estimateCPFromRides: true, evidence: bare).snapshot(asOf: now)
        #expect(snap.criticalPower != nil)
        #expect(snap.criticalPowerConfidence == .rough)
        #expect(snap.cyclingFTPConfidence == .thin)
    }

    /// The three share one posterior per date, so their series are resolved in one pass
    /// and must equal what each resolves alone.
    @Test func theCPFamilyResolvesTogetherAsItDoesApart() {
        let history = cycling()
        let together = history.estimatedSeries(PerformanceHistory.cpPosteriorKeys)
        for key in PerformanceHistory.cpPosteriorKeys {
            #expect(together[key]?.map(\.value) == history.estimatedSeries(key).map(\.value))
        }
        #expect(PerformanceHistory.seriesFamily(of: "w_prime") == PerformanceHistory.cpPosteriorKeys)
        #expect(PerformanceHistory.seriesFamily(of: "vo2max_cycling") == ["vo2max_cycling"])
    }

    /// The VO2max series has to carry VO2max, not the LT-pace default of the mapping.
    @Test func theVO2maxSeriesCarriesVO2max() throws {
        let series = cycling(ftp: false, cp: false, vo2: true).estimatedSeries("vo2max_cycling")
        let last = try #require(series.last)
        #expect(last.isEstimated)
        #expect((30 ... 90).contains(last.value))
    }

    @Test func noSeriesWithoutTheOptIn() {
        #expect(cycling(ftp: false, cp: false).estimatedSeries("cycling_ftp").isEmpty)
        #expect(cycling(ftp: false, cp: false).estimatedSeries("critical_power").isEmpty)
    }

    @Test func manualReadingsOutrankTheEstimate() {
        let snap = cycling(extra: ["cycling_ftp": [entry(ago(2), 250, rank: PerformanceHistory.manualRank)],
                                   "critical_power": [entry(ago(2), 280, rank: PerformanceHistory.manualRank)]])
            .snapshot(asOf: now)
        #expect(snap.cyclingFTP == 250 && !snap.cyclingFTPIsEstimated)
        #expect(snap.criticalPower == 280 && !snap.criticalPowerIsEstimated)
        #expect(snap.wPrimeIsEstimated)
    }

    /// Every ride reads the athlete of its own date, so a weight entered later moves no
    /// earlier value.
    @Test func aLaterWeightDoesNotMoveAnEarlierCP() throws {
        let heavier = cycling(extra: ["weight_kg": [entry(ago(100), 70), entry(ago(1), 80)]])
        let before = try #require(cycling().snapshot(asOf: ago(2)).criticalPower)
        #expect(heavier.snapshot(asOf: ago(2)).criticalPower == before)
        #expect(heavier.snapshot(asOf: now).criticalPower != before)
    }

    /// Without resting HR there is no reserve to scale by, so no cycling estimate at all —
    /// the synced FTP stands.
    @Test func missingRestingHRLeavesTheSyncedFTP() {
        let history = PerformanceHistory(
            byKey: ["max_hr": [entry(ago(100), 190)], "weight_kg": [entry(ago(100), 70)],
                    "cycling_ftp": [entry(ago(50), 240)]],
            estimateFTPFromCP: true, estimateCPFromRides: true, evidence: rides)
        let snap = history.snapshot(asOf: now)
        #expect(snap.cyclingFTP == 240 && !snap.cyclingFTPIsEstimated)
        #expect(snap.criticalPower == nil)
    }

    /// Scoring a run never pays for the cycling posterior.
    @Test func onlyRidesResolveTheCyclingEstimates() {
        #expect(PerformanceHistory.scoringKeys(sport: "cycling", multisport: false) == nil)
        #expect(PerformanceHistory.scoringKeys(sport: "running", multisport: true) == nil)
        let run = PerformanceHistory.scoringKeys(sport: "running", multisport: false)
        #expect(run?.contains("cycling_ftp") == false)
        #expect(run?.contains("lactate_threshold_speed") == true)
    }

    // MARK: LTHR from HRmax + sustained efforts

    /// Only running efforts speak to a running LTHR, so every fixture carries the family.
    private func run(_ date: Date, steady: Double, peak: Double) -> PerformanceHistory.ActivityEvidence {
        .init(date: date, steadyHR20: steady, peakHR: peak, family: .run)
    }

    @Test func lthrSeriesRisesWithAnObservedEffort() {
        let history = PerformanceHistory(
            byKey: ["max_hr": [entry(ago(200), 190)]],
            estimateFTPFromCP: false,
            estimateLTHRFromHRMax: true,
            evidence: [run(ago(100), steady: 175, peak: 185)])
        // 0.85 * 190 = 161.5 -> 162 while nothing has ever qualified; the effort clears
        // the 0.84 * 190 = 159.6 gate, and a lone effort is its own quantile.
        #expect(history.estimatedSeries("lactate_threshold_hr").map(\.value) == [162, 175, 175])
    }

    @Test func anEffortOlderThanTheWindowIsCarriedForwardNotDropped() {
        let history = PerformanceHistory(
            byKey: ["max_hr": [entry(ago(500), 190)]],
            estimateFTPFromCP: false,
            estimateLTHRFromHRMax: true,
            evidence: [run(ago(400), steady: 175, peak: 185)])
        // Outside the 365-day window the value holds at what the athlete last showed
        // rather than collapsing to the population fraction, which is a different
        // quantity and would read as a change in the athlete.
        #expect(history.snapshot(asOf: now).lactateThrHR == 175)
    }

    @Test func aManualMaxHROutranksASameDaySyncedOne() {
        let history = PerformanceHistory(
            byKey: ["max_hr": [entry(ago(1), 195),
                               entry(ago(1), 206, rank: PerformanceHistory.manualRank)]],
            estimateFTPFromCP: false,
            estimateLTHRFromHRMax: true)
        #expect(history.snapshot(asOf: now).lactateThrHR == 175)   // 0.85 * 206 = 175.1
    }

    @Test func anImplausibleReadingIsNoEvidence() {
        let history = PerformanceHistory(
            byKey: ["max_hr": [entry(ago(200), 190)]],
            estimateFTPFromCP: false,
            estimateLTHRFromHRMax: true,
            // Peaking above the athlete's maximum is a sensor fault, not an effort.
            evidence: [run(ago(100), steady: 175, peak: 205)])
        // Nothing moves, so the fraction's own date and today are the whole series.
        #expect(history.estimatedSeries("lactate_threshold_hr").map(\.value) == [162, 162])
    }

    // MARK: Chart stretches

    private func point(_ daysAgo: Double, _ value: Double,
                       _ confidence: EstimateConfidence?) -> MetricPoint {
        .init(date: ago(daysAgo), value: value, isEstimated: confidence != nil,
              confidence: confidence)
    }

    /// Styling per point makes one of them style the whole line, because `lineStyle`
    /// applies to a series — that drew a three-month window fully dashed and a
    /// six-month one fully solid off the same data. Each run of one styling has to
    /// become its own series, and the runs have to meet.
    @Test func stretchesSplitAtEveryStylingChangeAndShareTheirBoundary() {
        let series = [point(50, 3.0, .anchored), point(40, 3.1, .anchored),
                      point(30, 3.2, .stale), point(20, 3.2, .thin),
                      point(10, 3.4, .anchored)]
        let cut = MetricPoint.stretches(series)
        #expect(cut.map(\.isProvisional) == [false, true])
        // An edge is provisional when either end is, so the dashed run reaches back to
        // the last solid point and forward to the next one: the two lines meet.
        #expect(cut[0].points.map(\.value) == [3.0, 3.1])
        #expect(cut[1].points.map(\.value) == [3.1, 3.2, 3.2, 3.4])
    }

    @Test func aSeriesOfOneStylingIsOneStretch() {
        let solid = (0..<4).map { point(Double(40 - $0 * 10), 3.0, .anchored) }
        #expect(MetricPoint.stretches(solid).map(\.isProvisional) == [false])
        // A stored reading carries no confidence and is never provisional.
        let stored = (0..<4).map { point(Double(40 - $0 * 10), 3.0, nil) }
        #expect(MetricPoint.stretches(stored).map(\.isProvisional) == [false])
        // Nothing to draw a line between.
        #expect(MetricPoint.stretches([point(10, 3.0, .anchored)]).isEmpty)
    }

    // MARK: Cycling LTHR from power-gated rides

    /// A ride carrying its best 20-minute power and the heart rate held across those
    /// same minutes — the pair `LTHREstimate.Gate.power` reads.
    private func ride(_ date: Date, watts: Double, hr: Double) -> PerformanceHistory.ActivityEvidence {
        .init(date: date, steadyHR20: 0, peakHR: 190,
              submaxProfile: [LTHREstimate.windowSeconds: (watts: watts, hr: hr)], family: .bike)
    }

    /// On a bike the intensity is measured, so the gate runs on watts. A ride at a
    /// fraction of the athlete's own best 20-minute power says nothing about threshold
    /// however high its heart rate ran — that is a strap, not an effort.
    @Test func theCyclingThresholdHRGatesOnWattsNotOnHeartRate() {
        let snap = PerformanceHistory(
            byKey: ["max_hr": [entry(ago(400), 206)]],
            estimateFTPFromCP: false,
            estimateCyclingLTHRFromRides: true,
            evidence: [ride(ago(60), watts: 300, hr: 170), ride(ago(50), watts: 295, hr: 170),
                       ride(ago(40), watts: 290, hr: 170), ride(ago(30), watts: 298, hr: 170),
                       // 168 W is 56 % of the 300 W best, under the 85 % gate.
                       ride(ago(20), watts: 168, hr: 180)]).snapshot(asOf: now)
        #expect(snap.cyclingLactateThrHR == 170)
        #expect(snap.cyclingLactateThrHRIsEstimated)
        #expect(snap.cyclingLactateThrHRConfidence == .anchored)   // four gated rides
    }

    /// Nothing is *published* without a qualifying ride — the row stays empty rather
    /// than showing a population constant as a calculated value.
    @Test func noQualifyingRidePublishesNoCyclingValue() {
        let snap = PerformanceHistory(
            byKey: ["max_hr": [entry(ago(400), 206)],
                    "lactate_threshold_hr": [entry(ago(300), 182)]],
            estimateFTPFromCP: false,
            estimateCyclingLTHRFromRides: true).snapshot(asOf: now)
        #expect(snap.cyclingLactateThrHR == nil)
        #expect(!snap.cyclingLactateThrHRIsEstimated)
    }

    /// Every heart-rate consumer — zone bounds, HR-load TL, the planned-TL estimate —
    /// goes through this, so a ride is never scored against the running threshold once
    /// it has one of its own.
    @Test func thresholdHRSplitsByDiscipline() {
        var snap = PerformanceSnapshot()
        snap.maxHR = 206
        snap.lactateThrHR = 182
        // No ride evidence: the lower of the running value and 0.85 × 206 = 175.1 → 175.
        // The running value alone read 11 bpm above this athlete's measured 170.9, and
        // 19 above the second reference athlete's, because how far running sits above
        // cycling is itself athlete-specific.
        #expect(snap.thresholdHR(for: .bike) == 175)
        snap.cyclingLactateThrHR = 172
        #expect(snap.thresholdHR(for: .bike) == 172)
        #expect(snap.thresholdHR(for: .run) == 182)
        #expect(snap.thresholdHR(for: .swim) == 182)
    }

    /// The bound is a `min`, not a replacement: an athlete whose running threshold sits
    /// below the fraction keeps their own value rather than being raised to a constant.
    @Test func theBoundNeverRaisesTheStandIn() {
        var snap = PerformanceSnapshot()
        snap.maxHR = 206
        snap.lactateThrHR = 168          // below 0.85 × 206 = 175.1
        #expect(snap.thresholdHR(for: .bike) == 168)
    }

    // MARK: LT pace from reconstructed MAS

    /// A run carrying two settled in-band heart-rate buckets — one observation. `peakHR`
    /// clears the 206 bpm maximum every fixture below uses.
    private func paceRun(_ date: Date, _ speed: Double,
                         family: SportFamily = .run) -> PerformanceHistory.ActivityEvidence {
        .init(date: date, steadyHR20: 0, peakHR: 190, paceProfile: [170: speed, 175: speed - 0.1],
              family: family)
    }

    /// Runs five days apart from 92 days to a week ago, 3.0 m/s until 40 days ago and 3.2
    /// after — the filter answers from the fifth (72 days ago), so it is past its eight
    /// weeks of calibration today, at two levels.
    private var pacedRuns: [PerformanceHistory.ActivityEvidence] {
        stride(from: 92.0, through: 7, by: -5).map { paceRun(ago($0), $0 > 40 ? 3.0 : 3.2) }
    }

    private func runHistory(_ evidence: [PerformanceHistory.ActivityEvidence],
                            lthr: [PerformanceHistory.Entry]) -> PerformanceHistory {
        PerformanceHistory(
            byKey: ["max_hr": [entry(ago(400), 206)],
                    "resting_hr": [entry(ago(400), 48)],
                    "lactate_threshold_hr": lthr],
            estimateFTPFromCP: false,
            estimateLTPaceFromRuns: true,
            estimateRunningVO2maxFromRuns: true,
            evidence: evidence)
    }

    /// (184 - 48) / (206 - 48): the reserve held at the fixtures' LTHR.
    private let fraction = 136.0 / 158.0

    /// A triathlon or brick leg has a pace stream and a heart-rate stream like any run, but
    /// after hours of prior work heart rate no longer tracks the metabolic cost, so
    /// `MAS = v / %HRR` reads high. One race leg moved a real athlete's peak by 12 s/km.
    @Test func aMultisportLegIsNotEvidenceForRunningLTPace() {
        func pace(_ extra: [PerformanceHistory.ActivityEvidence]) -> Double? {
            runHistory(pacedRuns + extra, lthr: [entry(ago(300), 184)])
                .snapshot(asOf: now).lactateThrPaceSeconds
        }
        #expect(pace([]) != nil)
        #expect(pace([paceRun(ago(3), 5.0, family: .other)]) == pace([]))
    }

    /// Both run thresholds read one filtered MAS, so they can never describe two different
    /// athletes: the VO2max is its ACSM cost, the pace its share at threshold.
    @Test func runningVO2maxAndThresholdPaceReadTheSameReconstruction() throws {
        let snap = runHistory(pacedRuns, lthr: [entry(ago(300), 184)]).snapshot(asOf: now)
        let mas = (try #require(snap.vo2maxRunning) - 3.5) / (0.2 * 60)
        #expect(snap.lactateThrPaceSeconds == 1000 / LTPaceEstimate.ltSpeed(mas: mas, fractionOfMAS: fraction)!)
        #expect(snap.vo2maxRunningIsEstimated)
        #expect(snap.vo2maxRunningConfidence == .anchored)
    }

    private func ltPaceSeries(lthr: [PerformanceHistory.Entry]) -> [MetricPoint] {
        runHistory(pacedRuns, lthr: lthr).estimatedSeries("lactate_threshold_speed")
    }

    @Test func theLTPaceSeriesIsTheFilterAtEveryDate() throws {
        let runs = pacedRuns.map {
            LTPaceEstimate.Run(date: $0.date, profile: $0.paceProfile,
                               hrMax: VO2maxEstimate.hrMax(206, measured: ago(400), on: $0.date), hrRest: 48)
        }
        let track = try #require(LTPaceEstimate.track(runs: runs, sessions: []))
        let series = ltPaceSeries(lthr: [entry(ago(300), 184)])
        for point in series {
            let state = try #require(track.state(at: point.date))
            #expect(point.value == LTPaceEstimate.ltSpeed(mas: exp(state.log), fractionOfMAS: fraction))
        }
        // The faster block moves it: the pace today is quicker than the first answer.
        #expect(series.last!.value > series.first!.value)
    }

    /// The MAS fraction is a property of the athlete, so it sets the *level* of the
    /// series and must never touch its shape. Deriving it per date instead folded the
    /// threshold-HR series' own trajectory into the pace curve — on a real season this
    /// athlete's watch published 176 -> 184 -> 182 bpm, which is 6.8 % of fraction and
    /// ~20 s/km of movement that no run ever showed.
    @Test func aMovingThresholdHRDoesNotReshapeTheLTPaceSeries() {
        #expect(ltPaceSeries(lthr: [entry(ago(300), 176), entry(ago(100), 184)]).map(\.value)
                == ltPaceSeries(lthr: [entry(ago(300), 184)]).map(\.value))
    }

    /// Runs that stopped long ago still answer — marked stale, and lower by the detraining
    /// the filter charges for the months without a session.
    @Test func longPastRunsAnswerStaleAndDetrained() {
        let series = runHistory([185.0, 180, 175, 170, 165, 160, 155, 150, 145, 140, 135, 130]
                                    .map { paceRun(ago($0), 3.0) },
                                lthr: [entry(ago(300), 184)])
            .estimatedSeries("lactate_threshold_speed")
        #expect(series.last?.confidence == .stale)
        #expect(series.last!.value < series.map(\.value).max()!)
    }

    /// While the estimate cannot answer yet, the synced reading stands in — drawn dashed,
    /// because it is the watch's model and not ours. Once the estimate answers it is not a
    /// stand-in.
    @Test func aSyncedReadingStandingInForTheEstimateIsProvisional() throws {
        let series = PerformanceHistory(
            byKey: ["max_hr": [entry(ago(400), 206)],
                    "resting_hr": [entry(ago(400), 48)],
                    "vo2max_running": [entry(ago(120), 50)]],
            estimateFTPFromCP: false,
            estimateRunningVO2maxFromRuns: true,
            evidence: pacedRuns)
            .estimatedSeries("vo2max_running")
        let first = try #require(series.first)
        #expect(!first.isEstimated && first.isStandIn && first.isProvisional)
        #expect(series.last.map { $0.isEstimated && !$0.isStandIn } == true)
    }

    /// HRmax is the athlete's input: a hand-entered value stands over the one the watch
    /// keeps re-reporting, however recent that is.
    @Test func aManualMaxHRIsNotReplacedByALaterSyncedOne() {
        func maxHR(_ readings: [PerformanceHistory.Entry], asOf date: Date) -> Int? {
            PerformanceHistory(byKey: ["max_hr": readings], estimateFTPFromCP: false)
                .snapshot(asOf: date).maxHR
        }
        let manual = entry(ago(100), 204, rank: PerformanceHistory.manualRank)
        #expect(maxHR([entry(ago(300), 206), manual, entry(ago(10), 206)], asOf: now) == 204)
        // Before the athlete's value was entered, the synced one is all there is.
        #expect(maxHR([entry(ago(300), 206), manual, entry(ago(10), 206)], asOf: ago(200)) == 206)
    }

    /// A hand-entered value stands until the estimate rests on evidence newer than it: a
    /// threshold ride after an old entry moves the value on, a correction entered after the
    /// ride holds. Before any qualifying ride the entry is all there is.
    @Test func aManualCyclingLTHRStandsUntilANewerTestRide() {
        func lthr(manualDaysAgo: Double, asOf date: Date) -> (Int?, Bool) {
            let snap = PerformanceHistory(
                byKey: ["max_hr": [entry(ago(400), 204)],
                        "lactate_threshold_hr_cycling": [entry(ago(manualDaysAgo), 165,
                                                               rank: PerformanceHistory.manualRank)]],
                estimateFTPFromCP: false,
                estimateCyclingLTHRFromRides: true,
                evidence: [.init(date: ago(30), steadyHR20: 0, peakHR: 185,
                                 submaxProfile: [1200: (watts: 297, hr: 171)], family: .bike)])
                .snapshot(asOf: date)
            return (snap.cyclingLactateThrHR, snap.cyclingLactateThrHRIsEstimated)
        }
        #expect(lthr(manualDaysAgo: 60, asOf: ago(45)) == (165, false))   // no ride yet
        #expect(lthr(manualDaysAgo: 60, asOf: now) == (171, true))        // the test is newer
        #expect(lthr(manualDaysAgo: 10, asOf: now) == (165, false))       // the entry is newer
    }

    @Test func aCyclingEffortDoesNotSetTheRunningLTHR() {
        let history = PerformanceHistory(
            byKey: ["max_hr": [entry(ago(200), 190)]],
            estimateFTPFromCP: false,
            estimateLTHRFromHRMax: true,
            evidence: [.init(date: ago(100), steadyHR20: 178, peakHR: 185, family: .bike)])
        // Cycling LTHR runs 5-10 bpm under running LTHR in the same athlete, so a ride
        // must not answer for a run.
        #expect(history.snapshot(asOf: now).lactateThrHR == 162)
    }
}
