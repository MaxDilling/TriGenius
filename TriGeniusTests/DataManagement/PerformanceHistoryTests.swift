import Testing
import Foundation
@testable import TriGenius

// Pins `PerformanceHistory.estimatedSeries` — the progression of a threshold that
// has no stored series of its own (`FTPEstimate` / `LTHREstimate`), re-resolved at
// every date one of its inputs moved. Dates are relative to now because the
// resolver anchors the LTHR observation window on today.
struct PerformanceHistoryTests {

    private let now = Date()

    /// `days` ago.
    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func entry(_ date: Date, _ value: Double, rank: Int = 2) -> PerformanceHistory.Entry {
        .init(date: date, value: value, rank: rank)
    }

    // MARK: FTP from VO2max + mass

    @Test func ftpSeriesMovesWithItsInputs() {
        let history = PerformanceHistory(
            byKey: [
                "vo2max_cycling": [entry(ago(100), 50)],
                "weight_kg": [entry(ago(100), 70), entry(ago(10), 72)],
            ],
            estimateFTPFromVO2max: true)
        let series = history.estimatedSeries("cycling_ftp")
        // 0.0582413 * 50 * 70 = 203.84 -> 204; * 72 = 209.67 -> 210, held to today.
        #expect(series.map(\.value) == [204, 210, 210])
        #expect(series.map(\.isEstimated) == [true, true, true])
    }

    /// The series has to carry the metric it is named after. `estimatedSeries` maps the
    /// resolved snapshot back through a switch whose `default` is LT pace, so a key
    /// without its own case silently published pace under another metric's name.
    @Test func theVO2maxSeriesCarriesVO2maxAndNotThePaceDefault() {
        let history = PerformanceHistory(
            byKey: [
                "max_hr": [entry(ago(400), 206)],
                "resting_hr": [entry(ago(100), 48)],
                "weight_kg": [entry(ago(100), 75)],
                "vo2max_cycling": [entry(ago(100), 55)],
                "lactate_threshold_speed": [entry(ago(100), 3.7)],
            ],
            estimateFTPFromVO2max: false, estimateVO2maxFromRides: true)
        // No ride evidence, so the estimate cannot resolve and the stored reading stands:
        // 55 ml/kg/min, not the 3.7 m/s the pace default would have returned. Two points
        // — the reading's own date, then today, which is always appended.
        #expect(history.estimatedSeries("vo2max_cycling").map(\.value) == [55, 55])
    }

    @Test func noSeriesWithoutTheOptIn() {
        let history = PerformanceHistory(
            byKey: ["vo2max_cycling": [entry(ago(100), 50)], "weight_kg": [entry(ago(100), 70)]],
            estimateFTPFromVO2max: false)
        #expect(history.estimatedSeries("cycling_ftp").isEmpty)
    }

    @Test func manualReadingOutranksTheEstimate() {
        let history = PerformanceHistory(
            byKey: [
                "vo2max_cycling": [entry(ago(100), 50)],
                "weight_kg": [entry(ago(100), 70), entry(ago(10), 72)],
                "cycling_ftp": [entry(ago(50), 250, rank: PerformanceHistory.manualRank)],
            ],
            estimateFTPFromVO2max: true)
        let series = history.estimatedSeries("cycling_ftp")
        // 0.0582413 * 50 * 70 = 203.84 -> 204, then the manual reading takes over.
        // The weight change at -10 d no longer moves anything, so it is not a change point.
        #expect(series.map(\.value) == [204, 250, 250])
        #expect(series.map(\.isEstimated) == [true, false, false])
    }

    // MARK: LTHR from HRmax + sustained efforts

    /// Only running efforts speak to a running LTHR, so every fixture carries the family.
    private func run(_ date: Date, steady: Double, peak: Double) -> PerformanceHistory.ActivityEvidence {
        .init(date: date, steadyHR20: steady, peakHR: peak, family: .run)
    }

    @Test func lthrSeriesRisesWithAnObservedEffort() {
        let history = PerformanceHistory(
            byKey: ["max_hr": [entry(ago(200), 190)]],
            estimateFTPFromVO2max: false,
            estimateLTHRFromHRMax: true,
            evidence: [run(ago(100), steady: 175, peak: 185)])
        // 0.85 * 190 = 161.5 -> 162 while nothing has ever qualified; the effort clears
        // the 0.84 * 190 = 159.6 gate, and a lone effort is its own quantile.
        #expect(history.estimatedSeries("lactate_threshold_hr").map(\.value) == [162, 175, 175])
    }

    @Test func anEffortOlderThanTheWindowIsCarriedForwardNotDropped() {
        let history = PerformanceHistory(
            byKey: ["max_hr": [entry(ago(500), 190)]],
            estimateFTPFromVO2max: false,
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
            estimateFTPFromVO2max: false,
            estimateLTHRFromHRMax: true)
        #expect(history.snapshot(asOf: now).lactateThrHR == 175)   // 0.85 * 206 = 175.1
    }

    @Test func anImplausibleReadingIsNoEvidence() {
        let history = PerformanceHistory(
            byKey: ["max_hr": [entry(ago(200), 190)]],
            estimateFTPFromVO2max: false,
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
            estimateFTPFromVO2max: false,
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
            estimateFTPFromVO2max: false,
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

    /// A run carrying one settled heart-rate bucket. `peakHR` clears the 206 bpm
    /// maximum every fixture below uses.
    private func paceRun(_ date: Date, _ profile: [Int: Double]) -> PerformanceHistory.ActivityEvidence {
        .init(date: date, steadyHR20: 0, peakHR: 190, paceProfile: profile, family: .run)
    }

    /// Five runs at 3.0 m/s, then five at 3.2 m/s, all at 170 bpm — enough to fill the
    /// five-run window twice over at two distinct levels, so the series has a shape to
    /// compare rather than one point.
    private var pacedRuns: [PerformanceHistory.ActivityEvidence] {
        [80.0, 75, 70, 65, 60].map { paceRun(ago($0), [170: 3.0]) }
        + [40.0, 35, 30, 25, 20].map { paceRun(ago($0), [170: 3.2]) }
    }

    /// A triathlon or brick leg has a pace stream and a heart-rate stream like any
    /// run, and neither the estimator's steady-state assumption nor the pool the
    /// inflation constant was calibrated on: after hours of prior work heart rate no
    /// longer tracks the metabolic cost, so `MAS = v / %HRR` reads high. One race leg
    /// moved a real athlete's peak by 12 s/km.
    @Test func aMultisportLegIsNotEvidenceForRunningLTPace() {
        func pace(_ extra: [PerformanceHistory.ActivityEvidence]) -> Double {
            PerformanceHistory(
                byKey: ["max_hr": [entry(ago(400), 206)],
                        "resting_hr": [entry(ago(400), 48)],
                        "lactate_threshold_hr": [entry(ago(300), 184)]],
                estimateFTPFromVO2max: false,
                estimateLTPaceFromRuns: true,
                evidence: [40.0, 35, 30].map { paceRun(ago($0), [170: 3.0]) } + extra)
                .snapshot(asOf: now).lactateThrPaceSeconds!.rounded()
        }
        // Three runs at 3.0 m/s and 170 bpm answer 5:09 /km. The race leg runs the same
        // arithmetic to 5.0 * 158 / 122 = 6.48 m/s of MAS, which would drag q0.75 to
        // 4:25 — a minute of downhill in a race deciding the athlete's threshold.
        #expect(pace([]) == 309)
        #expect(pace([.init(date: ago(21), steadyHR20: 0, peakHR: 190,
                            paceProfile: [170: 5.0], family: .other)]) == 309)
    }

    /// Both run thresholds read one reconstruction, so they can never describe two
    /// different athletes — a second aggregation over the same pool could.
    @Test func runningVO2maxAndThresholdPaceReadTheSameReconstruction() {
        let snap = PerformanceHistory(
            byKey: ["max_hr": [entry(ago(400), 206)],
                    "resting_hr": [entry(ago(400), 48)],
                    "lactate_threshold_hr": [entry(ago(300), 184)]],
            estimateFTPFromVO2max: false,
            estimateLTPaceFromRuns: true,
            estimateRunningVO2maxFromRuns: true,
            evidence: pacedRuns).snapshot(asOf: now)
        // The window's p75 reconstruction is 3.2 * 158 / 122 = 4.1443 m/s of MAS. As a
        // pace that is 4.1443 * 0.83165 -> 4:50 /km; as oxygen uptake it is
        // 0.2 * 4.1443 * 60 + 3.5 = 53.2 ml/kg/min.
        #expect(snap.lactateThrPaceSeconds!.rounded() == 290)
        #expect(((snap.vo2maxRunning! * 10).rounded() / 10) == 53.2)
        #expect(snap.vo2maxRunningIsEstimated)
        #expect(snap.vo2maxRunningConfidence == .anchored)
    }

    private func ltPaceSeries(lthr: [PerformanceHistory.Entry]) -> [Double] {
        PerformanceHistory(
            byKey: ["max_hr": [entry(ago(400), 206)],
                    "resting_hr": [entry(ago(400), 48)],
                    "lactate_threshold_hr": lthr],
            estimateFTPFromVO2max: false,
            estimateLTPaceFromRuns: true,
            evidence: pacedRuns)
            .estimatedSeries("lactate_threshold_speed")
            .map { (1000 / $0.value).rounded() }
    }

    @Test func theLTPaceSeriesTracksTheWindowedQuantileOfReconstructedMAS() {
        // Reserve 206 - 48 = 158, so 3.0 m/s held at 170 bpm reconstructs
        // 3.0 * 158 / 122 = 3.8852 m/s of MAS and 3.2 m/s gives 4.1443. The fraction is
        // (184 - 48) / 158 / 1.035 = 0.83165, and the p75 across the window walks
        // 3.8852 -> 4.0148 -> 4.1443 as the faster runs displace the slower ones:
        // 5:09, 5:00, then 4:50 /km, held to today.
        #expect(ltPaceSeries(lthr: [entry(ago(300), 184)]) == [309, 300, 290, 290])
    }

    /// The MAS fraction is a property of the athlete, so it sets the *level* of the
    /// series and must never touch its shape. Deriving it per date instead folded the
    /// threshold-HR series' own trajectory into the pace curve — on a real season this
    /// athlete's watch published 176 -> 184 -> 182 bpm, which is 6.8 % of fraction and
    /// ~20 s/km of movement that no run ever showed.
    @Test func aMovingThresholdHRDoesNotReshapeTheLTPaceSeries() {
        #expect(ltPaceSeries(lthr: [entry(ago(300), 176), entry(ago(100), 184)])
                == ltPaceSeries(lthr: [entry(ago(300), 184)]))
    }

    /// Once no window holds enough runs the last value that did is republished —
    /// unchanged, and flagged, because the chart draws anything but a full window
    /// dashed and a solid line would make memory read as a measurement.
    @Test func aThinnedWindowIsCarriedForwardAndMarked() {
        let series = PerformanceHistory(
            byKey: ["max_hr": [entry(ago(400), 206)],
                    "resting_hr": [entry(ago(400), 48)],
                    "lactate_threshold_hr": [entry(ago(300), 184)]],
            estimateFTPFromVO2max: false,
            estimateLTPaceFromRuns: true,
            // Seven runs, all long past the 90-day window: the pool was full once and
            // nothing qualifies today.
            evidence: [180.0, 175, 170, 165, 160, 155, 150].map { paceRun(ago($0), [170: 3.0]) })
            .estimatedSeries("lactate_threshold_speed")
        #expect(series.contains { $0.confidence == .anchored })
        #expect(series.last?.confidence == .stale)
        // Held at the 5:09 /km the full window gave, not decayed away from it.
        #expect(series.allSatisfy { (1000 / $0.value).rounded() == 309 })
    }

    @Test func aCyclingEffortDoesNotSetTheRunningLTHR() {
        let history = PerformanceHistory(
            byKey: ["max_hr": [entry(ago(200), 190)]],
            estimateFTPFromVO2max: false,
            estimateLTHRFromHRMax: true,
            evidence: [.init(date: ago(100), steadyHR20: 178, peakHR: 185, family: .bike)])
        // Cycling LTHR runs 5-10 bpm under running LTHR in the same athlete, so a ride
        // must not answer for a run.
        #expect(history.snapshot(asOf: now).lactateThrHR == 162)
    }
}
