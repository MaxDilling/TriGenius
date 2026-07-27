import Testing
import Foundation
@testable import TriGenius

// Pins `buildSwimIntervals` end-to-end against a real captured swim (2026-07-14,
// 50 m pool) where Garmin's own per-lap distance under/over-counted three
// intervals (a missed wall-turn twice, a phantom fragment once). Values are the
// activity's real per-length FIT data; update alongside GarminTransformations.swift.

private func length(_ duration: Double, _ strokes: Int, _ stroke: String, distance: Double = 50) -> [String: Any] {
    ["duration": duration, "distance": distance, "totalNumberOfStrokes": strokes, "swimStroke": stroke]
}

private func idleLength(_ duration: Double) -> [String: Any] {
    ["duration": duration, "distance": 0, "totalNumberOfStrokes": 0, "swimStroke": ""]
}

private func restLap(_ duration: Double) -> [String: Any] {
    ["duration": duration, "distance": 0, "numberOfActiveLengths": 0]
}

private let realSwimLaps: [[String: Any]] = [
    // Interval 1: 4 lengths, nothing anomalous — Garmin's raw 200 m is already right.
    [
        "duration": 289.531, "distance": 200, "numberOfActiveLengths": 4, "averageHR": 112, "maxHR": 125,
        "totalNumberOfStrokes": 139, "averageSWOLF": 107,
        "lengthDTOs": [
            length(70.937, 32, "backstroke"), length(74.625, 35, "backstroke"),
            length(74.75, 37, "backstroke"), length(69.219, 35, "backstroke")
        ]
    ],
    // Interval 2: Garmin's raw 150 m (3 active lengths) — length #2 (169.937 s / 67
    // strokes, ~2.2× the session median) is a missed wall-turn; the idle length
    // folded into this lap is correctly excluded either way. True: 200 m / 4 lengths.
    [
        "duration": 369.511, "distance": 150, "numberOfActiveLengths": 3, "averageHR": 128, "maxHR": 141,
        "totalNumberOfStrokes": 139, "averageSWOLF": 158,
        "lengthDTOs": [
            idleLength(36.0), length(82.375, 39, "breaststroke"),
            length(169.937, 67, "breaststroke"), length(81.199, 33, "breaststroke")
        ]
    ],
    restLap(50.401),
    // Interval 3: Garmin's raw 350 m (7 active lengths) — length #3 (145.687 s / 67
    // strokes) is another missed wall-turn. True: 400 m / 8 lengths.
    [
        "duration": 613.994, "distance": 350, "numberOfActiveLengths": 7, "averageHR": 142, "maxHR": 156,
        "totalNumberOfStrokes": 281, "averageSWOLF": 128,
        "lengthDTOs": [
            length(76.625, 33, "breaststroke"), length(74.75, 35, "breaststroke"),
            length(145.687, 67, "breaststroke"), length(68.0, 31, "backstroke"),
            length(90.562, 41, "breaststroke"), length(78.812, 37, "breaststroke"),
            length(79.558, 37, "breaststroke")
        ]
    ],
    // Interval 4: Garmin's raw 150 m (3 active lengths) — length #1 (47.75 s / 13
    // strokes) is a phantom fragment absorbed into its neighbour. True: 100 m / 2.
    [
        "duration": 190.965, "distance": 150, "numberOfActiveLengths": 3, "averageHR": 135, "maxHR": 145,
        "totalNumberOfStrokes": 74, "averageSWOLF": 88,
        "lengthDTOs": [
            length(47.75, 13, "breaststroke"), length(56.0, 27, "breaststroke"),
            length(87.215, 34, "breaststroke")
        ]
    ],
    restLap(30.322),
    // Interval 5: Garmin's raw 50 m (1 active length) — the one length (181.452 s /
    // 73 strokes, ~2.3×) is a missed wall-turn. True: 100 m / 2 lengths.
    [
        "duration": 181.452, "distance": 50, "numberOfActiveLengths": 1, "averageHR": 124, "maxHR": 135,
        "totalNumberOfStrokes": 73, "averageSWOLF": 254,
        "lengthDTOs": [length(181.452, 73, "breaststroke")]
    ]
]

@Test func buildSwimIntervals_recoversMissedWallTurnsAndFragments() {
    let intervals = GarminTransform.buildSwimIntervals(realSwimLaps, poolLengthM: 50)
    let active = intervals.filter { ($0["is_rest"] as? Bool) != true }
    #expect(active.map { $0["distance_m"] as? Double } == [200, 200, 400, 100, 100])
    #expect(active.map { $0["lengths"] as? Int } == [4, 4, 8, 2, 2])
}

@Test func buildSwimIntervals_preservesGarminRawAlongsideCleaned() {
    let intervals = GarminTransform.buildSwimIntervals(realSwimLaps, poolLengthM: 50)
    let active = intervals.filter { ($0["is_rest"] as? Bool) != true }
    // Garmin's original (uncorrected) per-lap claim survives alongside the fix.
    #expect(active.map { $0["garmin_distance_m"] as? Double } == [200, 150, 350, 150, 50])
    #expect(active.map { $0["garmin_lengths"] as? Int } == [4, 3, 7, 3, 1])
}

@Test func buildSwimIntervals_cumulativeDistanceMatchesCorrectedTotal() {
    let intervals = GarminTransform.buildSwimIntervals(realSwimLaps, poolLengthM: 50)
    #expect(intervals.last { ($0["is_rest"] as? Bool) != true }?["cumulative_distance_m"] as? Double == 1000)
}

@Test func buildSwimIntervals_restRowsUnaffected() {
    let intervals = GarminTransform.buildSwimIntervals(realSwimLaps, poolLengthM: 50)
    let rests = intervals.filter { ($0["is_rest"] as? Bool) == true }
    #expect(rests.map { $0["time_sec"] as? Double } == [50.4, 30.3])
}

// MARK: - flattenActivity
//
// Pins the key renaming that lets a multisport parent's children (fetched from
// `/activity/{id}`, whose summary is nested and differently spelled) run through
// the same formatter as an activity-list entry. Values are lifted verbatim from
// the real bike leg in ref/garmin_api/multisportChild_bike.json.

private let bikeChildDTO: [String: Any] = [
    "activityId": 23736636527,
    "activityName": "Road Cycling",
    "parentId": 23736636815,
    "locationName": "Wörthsee",
    "activityTypeDTO": ["typeId": 10, "typeKey": "road_biking"],
    "summaryDTO": [
        "startTimeLocal": "2026-07-26T09:32:48.0",
        "startTimeGMT": "2026-07-26T07:32:48.0",
        "distance": 43850.08, "duration": 4937.983,
        "averageSpeed": 8.88, "maxSpeed": 16.945,
        "averagePower": 224.0, "maxPower": 872.0, "normalizedPower": 252.0,
        "averageHR": 160.0, "maxHR": 176.0, "calories": 1218.0,
        "elevationGain": 524.29, "elevationLoss": 536.74,
        "averageBikeCadence": 80.0
    ]
]

@Test func flattenActivity_liftsTheSummaryAndRenamesToListKeys() {
    let flat = GarminTransform.flattenActivity(bikeChildDTO)
    #expect((flat["activityType"] as? [String: Any])?["typeKey"] as? String == "road_biking")
    #expect(flat["startTimeLocal"] as? String == "2026-07-26T09:32:48.0")
    #expect(Coerce.double(flat["duration"]) == 4937.983)
    #expect(Coerce.double(flat["distance"]) == 43850.08)
    // The renames the formatter depends on: without them the bike leg would lose
    // its normalized power and score no power TSS.
    #expect(Coerce.double(flat["avgPower"]) == 224.0)
    #expect(Coerce.double(flat["normPower"]) == 252.0)
    #expect(flat["locationName"] as? String == "Wörthsee")
    // The detail DTO spells bike cadence `averageBikeCadence`, not the list's
    // `averageBikingCadenceInRevPerMinute`.
    #expect(Coerce.double(flat["avgBikingCadenceInRevPerMinute"]) == 80.0)
}

@Test func flattenActivity_keysTheDTOLacksStayAbsent() {
    let flat = GarminTransform.flattenActivity(bikeChildDTO)
    // Children carry no time-in-zone — absence must stay absence, not a zero dict.
    #expect(flat["hrTimeInZone_1"] == nil)
    #expect(flat["averageRunningCadenceInStepsPerMinute"] == nil)
}

@Test func timestamp_parsesGarminsFractionalGMTStamp() {
    let start = GarminTransform.timestamp("2026-07-26T06:46:01.0")
    let bikeStart = GarminTransform.timestamp("2026-07-26T07:32:48.0")
    #expect(start != nil)
    // The swim→bike offset the segment layer stores: 46:47 into the session.
    #expect(bikeStart?.timeIntervalSince(start!) == 2807)
}

// MARK: - metricSamples
//
// Offsets are measured from the activity's start, not from the metric's first
// sample. A triathlon's `directPower` only begins on the bike leg; anchoring it
// to itself slid the whole power stream to t=0, so the detail view charted the
// ride's power under the swim and the run's cadence under the bike.

/// Three rows 1 s apart; power is missing until the third.
private let lateStartingMetricDetails: [String: Any] = [
    "metricDescriptors": [
        ["key": "directTimestamp", "metricsIndex": 0],
        ["key": "directPower", "metricsIndex": 1]
    ],
    "activityDetailMetrics": [
        ["metrics": [1_785_000_000_000, NSNull()]],
        ["metrics": [1_785_000_001_000, NSNull()]],
        ["metrics": [1_785_000_002_000, 224]]
    ]
]

@Test func metricSamples_offsetsRunFromTheActivityStartNotTheMetricsFirstSample() {
    let samples = GarminTransform.metricSamples(lateStartingMetricDetails, key: "directPower")
    #expect(samples.map(\.offset) == [2])
    #expect(samples.map(\.value) == [224])
}

@Test func timestamp_rejectsNonStrings() {
    #expect(GarminTransform.timestamp(nil) == nil)
    #expect(GarminTransform.timestamp(42) == nil)
}
