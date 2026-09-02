import Foundation
import Testing
@testable import TriGenius

// Golden-master pins for the zone model. Expected bounds are hand-computed from the
// fractions in TSSConstants; expected seconds are the literal z1…z5 buckets. Update
// alongside Analytics/ZoneModel.swift — the pins are the spec.

// MARK: Bounds

@Test func hrBounds_areZoneLoadMidpointsOfLTHR() {
    var snap = PerformanceSnapshot()
    snap.lactateThrHR = 160
    // Midpoints of [0.74, 0.84, 0.89, 0.94, 1.03] = [0.79, 0.865, 0.915, 0.985] × 160.
    let bounds = ZoneMetric.heartRate.upperBounds(snapshot: snap, family: .run)
    #expect(bounds == [126.4, 138.4, 146.4, 157.6])
}

@Test func hrBounds_absentWithoutMeasuredLTHR() {
    #expect(ZoneMetric.heartRate.upperBounds(snapshot: PerformanceSnapshot(), family: .run) == nil)
}

@Test func paceBounds_areFractionsOfThresholdSpeed() {
    var snap = PerformanceSnapshot()
    snap.lactateThrPaceSeconds = 300          // 5:00/km → 3.333… m/s threshold speed
    let bounds = ZoneMetric.pace.upperBounds(snapshot: snap, family: .run)
    let expected = [0.78, 0.88, 0.94, 1.00].map { $0 * (1000.0 / 300.0) }
    #expect(bounds == expected)
    #expect(bounds?.last == 1000.0 / 300.0)   // z4/z5 line sits exactly at threshold
}

@Test func paceBounds_onlyForRunning() {
    var snap = PerformanceSnapshot()
    snap.lactateThrPaceSeconds = 300
    #expect(ZoneMetric.pace.upperBounds(snapshot: snap, family: .bike) == nil)
    #expect(ZoneMetric.pace.upperBounds(snapshot: snap, family: .swim) == nil)
}

@Test func powerBounds_areFractionsOfFTP() {
    var snap = PerformanceSnapshot()
    snap.cyclingFTP = 250
    #expect(ZoneMetric.power.upperBounds(snapshot: snap, family: .bike) == [137.5, 187.5, 225.0, 262.5])
    #expect(ZoneMetric.power.upperBounds(snapshot: snap, family: .run) == nil)
}

// MARK: Bucketing

@Test func seconds_bucketsBySampleValue() {
    let bounds = [100.0, 120.0, 140.0, 160.0]
    let samples: [NormalizedStream.Sample] = [
        (value: 90, seconds: 10),    // z1
        (value: 100, seconds: 5),    // z1 — the bound itself belongs to the lower zone
        (value: 130, seconds: 20),   // z3
        (value: 200, seconds: 3),    // z5 — open-ended above the last bound
    ]
    #expect(ZoneBucketing.seconds(samples, upperBounds: bounds) == [15, 0, 20, 0, 3])
}

@Test func seconds_nilWhenNothingLanded() {
    #expect(ZoneBucketing.seconds([], upperBounds: [1, 2, 3, 4]) == nil)
    #expect(ZoneBucketing.seconds([(value: 5, seconds: 0)], upperBounds: [1, 2, 3, 4]) == nil)
}

@Test func durationSamples_weightByGapToNextReading() {
    let points: [(offset: Double, value: Double)] = [(0, 100), (1, 110), (5, 120)]
    let samples = ZoneBucketing.durationSamples(points)
    #expect(samples.map(\.seconds) == [1, 4, 1])   // last reading stands for one second
    #expect(samples.map(\.value) == [100, 110, 120])
}

@Test func durationSamples_capRecordingPause() {
    // A 10-minute gap is a paused recording, not ten minutes in that zone.
    let samples = ZoneBucketing.durationSamples([(0, 100), (600, 110)])
    #expect(samples.map(\.seconds) == [30, 1])
}

// MARK: Writing into the details schema

@Test func apply_writesEachMetricAtItsOwnPath() {
    var snap = PerformanceSnapshot()
    snap.lactateThrHR = 160
    snap.lactateThrPaceSeconds = 300
    var details: [String: Any] = ["sport": "running"]
    let thresholdSpeed = 1000.0 / 300.0
    ZoneBucketing.apply([
        .heartRate: [(value: 120, seconds: 60), (value: 150, seconds: 30)],
        .pace: [(value: thresholdSpeed * 0.5, seconds: 100), (value: thresholdSpeed * 1.1, seconds: 20)],
    ], to: &details, snapshot: snap)

    #expect(details["hr_zones_seconds"] as? [String: Int] == ["z1": 60, "z2": 0, "z3": 0, "z4": 30, "z5": 0])
    let running = details["running"] as? [String: Any]
    #expect(running?["pace_zones_seconds"] as? [String: Int] == ["z1": 100, "z2": 0, "z3": 0, "z4": 0, "z5": 20])
}

@Test func apply_leavesMetricAloneWithoutThreshold() {
    var details: [String: Any] = ["sport": "running"]
    ZoneBucketing.apply([.heartRate: [(value: 120, seconds: 60)]],
                        to: &details, snapshot: PerformanceSnapshot())
    #expect(details["hr_zones_seconds"] == nil)
}

@Test func apply_paceIsAbsentOnABike() {
    var snap = PerformanceSnapshot()
    snap.lactateThrPaceSeconds = 300
    var details: [String: Any] = ["sport": "cycling"]
    ZoneBucketing.apply([.pace: [(value: 10, seconds: 60)]], to: &details, snapshot: snap)
    #expect(details["running"] == nil)
}

// MARK: Reading the zones back out

@Test func apply_recordsTheBoundsItBucketedAgainst() {
    var snap = PerformanceSnapshot()
    snap.lactateThrHR = 160
    var details: [String: Any] = ["sport": "running"]
    ZoneBucketing.apply([.heartRate: [(value: 120, seconds: 60)]], to: &details, snapshot: snap)
    #expect(ZoneDistribution.zoneBounds(details: details, metric: .heartRate) == [126.4, 138.4, 146.4, 157.6])
}

@Test func zoneBounds_nilForARecordWithoutThem() {
    let details: [String: Any] = ["hr_zones_seconds": ["z1": 600]]
    #expect(ZoneDistribution.zoneBounds(details: details, metric: .heartRate) == nil)
}

// MARK: Describing a zone to the athlete

@Test func rangeText_readsOpenEndedAtBothEnds() {
    let bounds = [126.4, 138.4, 146.4, 157.6]
    #expect(ZoneMetric.heartRate.rangeText(zone: 0, bounds: bounds) == "< 126 bpm")
    #expect(ZoneMetric.heartRate.rangeText(zone: 2, bounds: bounds) == "138 – 146 bpm")
    #expect(ZoneMetric.heartRate.rangeText(zone: 4, bounds: bounds) == "> 158 bpm")
}

@Test func rangeText_paceInvertsSpeedIntoPace() {
    // 5:00/km threshold → bounds in m/s; Z1 is the SLOW end, Z5 the fast one.
    let bounds = [0.78, 0.88, 0.94, 1.00].map { $0 * (1000.0 / 300.0) }
    #expect(ZoneMetric.pace.rangeText(zone: 0, bounds: bounds) == "slower than 6:25 /km")
    #expect(ZoneMetric.pace.rangeText(zone: 2, bounds: bounds) == "5:41 – 5:19 /km")
    #expect(ZoneMetric.pace.rangeText(zone: 4, bounds: bounds) == "faster than 5:00 /km")
}

@Test func fractionText_isTheModel_notTheAthletesNumbers() {
    #expect(ZoneMetric.pace.fractionText(zone: 4) == "≥ 100 % of threshold speed")
    #expect(ZoneMetric.power.fractionText(zone: 0) == "< 55 % of FTP")
    #expect(ZoneMetric.heartRate.fractionText(zone: 1) == "79–87 % of LTHR")
}
