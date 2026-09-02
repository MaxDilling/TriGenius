import Foundation
import Testing
@testable import TriGenius

// Golden-master pins for the shared zone-dict reader. Expected arrays are the
// literal z1…z5 values. Update alongside Analytics/ZoneDistribution.swift; the
// bucketing that writes these dicts is pinned in ZoneModelTests.

@Test func hrZones_readsZ1toZ5() {
    let details: [String: Any] = ["hr_zones_seconds": ["z1": 600, "z2": 1200, "z3": 300, "z4": 60, "z5": 0]]
    #expect(ZoneDistribution.zoneSeconds(details: details, metric: .heartRate) == [600, 1200, 300, 60, 0])
}

@Test func missingKey_isNil() {
    #expect(ZoneDistribution.zoneSeconds(details: [:], metric: .heartRate) == nil)
}

@Test func allZero_isNil() {
    let details: [String: Any] = ["hr_zones_seconds": ["z1": 0, "z2": 0, "z3": 0, "z4": 0, "z5": 0]]
    #expect(ZoneDistribution.zoneSeconds(details: details, metric: .heartRate) == nil)
}

@Test func power_readsNestedCyclingKey() {
    let details: [String: Any] = ["cycling": ["power_zones_seconds": ["z1": 100, "z2": 200, "z3": 300, "z4": 400, "z5": 500]]]
    #expect(ZoneDistribution.zoneSeconds(details: details, metric: .power) == [100, 200, 300, 400, 500])
}

@Test func power_absentWhenNoCyclingBlock() {
    let details: [String: Any] = ["hr_zones_seconds": ["z1": 600]]
    #expect(ZoneDistribution.zoneSeconds(details: details, metric: .power) == nil)
}

@Test func pace_readsNestedRunningKey() {
    let details: [String: Any] = ["running": ["pace_zones_seconds": ["z1": 60, "z2": 120, "z3": 180, "z4": 30, "z5": 10]]]
    #expect(ZoneDistribution.zoneSeconds(details: details, metric: .pace) == [60, 120, 180, 30, 10])
}
