import Testing
import Foundation
@testable import TriGenius

// Pins for the multisport segment layer: the JSON round-trip and the per-leg
// TSS sum. Expected TSS values are the hand-computed IF²·h·100 of each leg —
// the same numbers `TSSCalculatorTests` pins for those legs standalone, which
// is the point: a leg scores identically inside a session and on its own.

private func snapshot(ftp: Int? = nil, runThrPace: Double? = nil, css: Double? = nil) -> PerformanceSnapshot {
    PerformanceSnapshot(cyclingFTP: ftp, runningFTP: nil, cssPaceSeconds: css,
                        lactateThrHR: nil, maxHR: nil, lactateThrPaceSeconds: runThrPace,
                        vo2maxRunning: nil, vo2maxCycling: nil, weightKg: nil)
}

private let swimLeg: [String: Any] = ["sport": "lap_swimming", "duration_minutes": 60,
                                      "distance_km": 3.0, "swimming": ["swim_time_s": 3600]]
private let bikeLeg: [String: Any] = ["sport": "cycling", "duration_minutes": 60,
                                      "distance_km": 40.0, "cycling": ["normalized_power_w": 200]]
private let runLeg: [String: Any] = ["sport": "running", "duration_minutes": 60,
                                     "distance_km": 10.0, "running": ["normalized_pace_s_per_km": 300]]
private let transitionLeg: [String: Any] = ["sport": "transition", "duration_minutes": 2]

@Test func encodeDecode_roundTripsEveryField() {
    let streams = WorkoutStreams.encode(spanSeconds: 60, metrics: [.cadence: [(0, 85)]])
    let segments = [WorkoutSegment(offsetSeconds: 90, sourceId: "garmin:1", tss: 64,
                                   tssBasis: "normalized power vs FTP", details: bikeLeg,
                                   streamsData: streams)]
    let decoded = WorkoutSegments.decode(WorkoutSegments.encode(segments))
    #expect(decoded.count == 1)
    #expect(decoded[0].offsetSeconds == 90)
    #expect(decoded[0].sourceId == "garmin:1")
    #expect(decoded[0].tss == 64)
    #expect(decoded[0].tssBasis == "normalized power vs FTP")
    #expect(decoded[0].family == .bike)
    #expect(decoded[0].distanceKm == 40.0)
    #expect(decoded[0].durationMinutes == 60)
    // The leg's own streams survive the base64 round trip — the bike leg charts
    // rpm, which the parent's single steps/min series can't provide.
    #expect(WorkoutStreams.decode(decoded[0].streamsData)?.metrics[.cadence]?.first == 85)
}

@Test func encode_emptySegmentsIsEmptyString() {
    #expect(WorkoutSegments.encode([]) == "")
    #expect(WorkoutSegments.decode("").isEmpty)
}

@Test func scoreSegments_sumsEachLegAgainstItsOwnDiscipline() {
    // swim 56 (css 90 vs 120 s/100m) + bike 64 (IF 0.8) + run 64 (IF 0.8) = 184.
    // The transition scores nothing — no intensity data, nothing substituted.
    var segments = [swimLeg, transitionLeg, bikeLeg, transitionLeg, runLeg].enumerated().map {
        WorkoutSegment(offsetSeconds: Double($0.offset) * 3600, sourceId: nil,
                       tss: nil, tssBasis: nil, details: $0.element)
    }
    let r = TSSScoring.scoreSegments(&segments, snapshot: snapshot(ftp: 250, runThrPace: 240, css: 90),
                                     zoneSamples: [:])
    #expect(r.tss == 184)
    #expect(r.distanceKm == 53.0)
    #expect(segments[0].tss == 56)
    #expect(segments[2].tss == 64)
    #expect(segments[4].tss == 64)
    #expect(segments[1].tss == nil)
    #expect(r.basis == "segments: swim pace vs CSS (cleaned distance) "
            + "+ normalized power vs FTP + normalized pace vs threshold pace")
}

@Test func scoreSegments_noScorableLegYieldsNoTSS() {
    var segments = [WorkoutSegment(offsetSeconds: 0, sourceId: nil, tss: nil,
                                   tssBasis: nil, details: transitionLeg)]
    let r = TSSScoring.scoreSegments(&segments, snapshot: snapshot(), zoneSamples: [:])
    #expect(r.tss == nil)
    #expect(r.basis == nil)
}

@MainActor
@Test func sportContributions_singleSportRowIsItself() {
    let r = WorkoutRecord(id: "garmin:1", source: "garmin", date: Date(), sport: "cycling",
                          name: "Ride", isCompleted: true, durationMinutes: 60,
                          distanceKm: 40, tss: 64)
    let c = r.sportContributions
    #expect(c.count == 1)
    #expect(c[0].family == .bike)
    #expect(c[0].tss == 64)
    #expect(c[0].distanceKm == 40)
}

@MainActor
@Test func sportContributions_multisportRowSplitsPerLeg() {
    let segments = [
        WorkoutSegment(offsetSeconds: 0, sourceId: nil, tss: 56, tssBasis: nil, details: swimLeg),
        WorkoutSegment(offsetSeconds: 3600, sourceId: nil, tss: 64, tssBasis: nil, details: bikeLeg),
        WorkoutSegment(offsetSeconds: 7200, sourceId: nil, tss: 64, tssBasis: nil, details: runLeg)
    ]
    let r = WorkoutRecord(id: "garmin:1", source: "garmin", date: Date(), sport: "multi_sport",
                          name: "Triathlon", isCompleted: true, durationMinutes: 182,
                          distanceKm: 53, tss: 184,
                          segmentsJSON: WorkoutSegments.encode(segments))
    let c = r.sportContributions
    #expect(c.map(\.family) == [.swim, .bike, .run])
    #expect(c.map(\.tss) == [56, 64, 64])
    #expect(c.map(\.distanceKm) == [3.0, 40.0, 10.0])
}

@MainActor
@Test func detailDicts_multisportYieldsOnePerLegNotTheParent() {
    let segments = [WorkoutSegment(offsetSeconds: 0, sourceId: nil, tss: nil,
                                   tssBasis: nil, details: bikeLeg)]
    let r = WorkoutRecord(id: "garmin:1", source: "garmin", date: Date(), sport: "multi_sport",
                          name: "Brick", isCompleted: true,
                          detailsJSON: #"{"sport":"multi_sport"}"#,
                          segmentsJSON: WorkoutSegments.encode(segments))
    #expect(r.detailDicts.count == 1)
    #expect(r.detailDicts[0]["sport"] as? String == "cycling")
}
