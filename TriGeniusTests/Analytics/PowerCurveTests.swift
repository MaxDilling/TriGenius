import Foundation
import Testing
@testable import TriGenius

// Golden-master pins for the shared power-curve core. Expected watts are
// hand-computed rolling means. Update alongside Analytics/PowerCurve.swift.

@Test func maxMeans_singleSegment() {
    let curve = PowerCurve.maxMeans(segments: [[100, 200, 300, 400]])
    #expect(curve == [1: 400, 2: 350, 3: 300])
}

@Test func maxMeans_windowNeverSpansGap() {
    let curve = PowerCurve.maxMeans(segments: [[300, 300], [500]])
    #expect(curve == [1: 500, 2: 300])
}

@Test func maxMeans_durationLongerThanData_absent() {
    let curve = PowerCurve.maxMeans(segments: [[200, 200]])
    #expect(curve[3] == nil)
}

@Test func encode_pinsExactString() {
    #expect(PowerCurve.encode([60: 250, 1: 400.5]) == "[[1,400.5],[60,250]]")
}

@Test func encode_emptyCurve_isEmptyString() {
    #expect(PowerCurve.encode([:]) == "")
}

@Test func decode_roundTripsEncode() {
    #expect(PowerCurve.decode(PowerCurve.encode([1: 400.5, 60: 250])) == [1: 400.5, 60: 250])
}

@Test func aggregate_elementWiseMaxWithAttribution() {
    let day1 = Date(timeIntervalSince1970: 1_700_000_000)
    let day2 = Date(timeIntervalSince1970: 1_700_100_000)
    let points = PowerCurve.aggregate([
        (id: "a", name: "Ride A", date: day1, curve: [60: 300, 300: 250]),
        (id: "b", name: "Ride B", date: day2, curve: [60: 320, 1200: 200])
    ])
    #expect(points == [
        PowerCurve.Point(durationSeconds: 60, watts: 320, activityId: "b", activityName: "Ride B", date: day2),
        PowerCurve.Point(durationSeconds: 300, watts: 250, activityId: "a", activityName: "Ride A", date: day1),
        PowerCurve.Point(durationSeconds: 1200, watts: 200, activityId: "b", activityName: "Ride B", date: day2)
    ])
}

@Test func durationLabel_pins() {
    #expect(PowerCurve.durations.map(PowerCurve.durationLabel).joined(separator: ",") ==
        "1s,2s,3s,5s,8s,10s,15s,20s,30s,45s,1m,1m30s,2m,2m30s,3m,4m,5m,7m,10m,15m,20m,30m,40m,1h,1h30m,2h,3h,4h,5h,6h")
}
