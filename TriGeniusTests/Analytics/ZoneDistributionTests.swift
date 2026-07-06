import Foundation
import Testing
@testable import TriGenius

// Golden-master pins for the shared zone-dict reader. Expected arrays are the
// literal z1…z5 values. Update alongside Analytics/ZoneDistribution.swift.

@Test func hrZones_readsZ1toZ5() {
    let details: [String: Any] = ["hr_zones_seconds": ["z1": 600, "z2": 1200, "z3": 300, "z4": 60, "z5": 0]]
    #expect(ZoneDistribution.zoneSeconds(details: details, source: .heartRate) == [600, 1200, 300, 60, 0])
}

@Test func missingKey_isNil() {
    #expect(ZoneDistribution.zoneSeconds(details: [:], source: .heartRate) == nil)
}

@Test func allZero_isNil() {
    let details: [String: Any] = ["hr_zones_seconds": ["z1": 0, "z2": 0, "z3": 0, "z4": 0, "z5": 0]]
    #expect(ZoneDistribution.zoneSeconds(details: details, source: .heartRate) == nil)
}

@Test func power_readsNestedCyclingKey() {
    let details: [String: Any] = ["cycling": ["power_zones_seconds": ["z1": 100, "z2": 200, "z3": 300, "z4": 400, "z5": 500]]]
    #expect(ZoneDistribution.zoneSeconds(details: details, source: .power) == [100, 200, 300, 400, 500])
}

@Test func power_absentWhenNoCyclingBlock() {
    let details: [String: Any] = ["hr_zones_seconds": ["z1": 600]]
    #expect(ZoneDistribution.zoneSeconds(details: details, source: .power) == nil)
}
