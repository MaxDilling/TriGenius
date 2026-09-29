import Foundation
import Testing
@testable import TriGenius

// Golden-master pins for the activity list. Update alongside Analytics/ActivityList.swift.

private let cal = Calendar.current
private let monday = TrainingVolume.weekStart(of: Date(timeIntervalSince1970: 1_700_000_000))
private func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: monday)! }

@MainActor
private func item(_ name: String, _ sport: String, on d: Int, minutes: Double = 60, km: Double = 10,
                  tss: Double? = 50, legs: [[String: Any]] = []) -> ActivityListItem {
    let segments = legs.map { WorkoutSegment(offsetSeconds: 0, sourceId: nil, tss: $0["tss"] as? Double,
                                             tssBasis: nil, details: $0) }
    return ActivityListItem(WorkoutRecord(
        id: name, source: "garmin", date: day(d), sport: sport, name: name, isCompleted: true,
        durationMinutes: minutes, distanceKm: km, tss: tss,
        segmentsJSON: segments.isEmpty ? "" : WorkoutSegments.encode(segments)))
}

@MainActor
private func sample() -> [ActivityListItem] {
    [item("Brick", "multi_sport", on: 8, minutes: 90, km: 50, tss: 100, legs: [
        ["sport": "cycling", "duration_minutes": 60.0, "distance_km": 40.0, "tss": 60.0],
        ["sport": "running", "duration_minutes": 30.0, "distance_km": 10.0, "tss": 40.0]]),
     item("Munich Cycling", "cycling", on: 7, minutes: 120, km: 60, tss: 90),
     item("FTP-Test 20 min", "cycling", on: 2, tss: 80),
     item("Lockerer Lauf", "running", on: 0, minutes: 45, km: 8, tss: nil)]
}

@MainActor
@Test func weeks_groupNewestFirstWithWholeSessionTotals() {
    let weeks = ActivityList.weeks(sample(), sport: nil, query: "")
    #expect(weeks.map(\.weekStart) == [day(7), day(0)])
    #expect(weeks.map { $0.items.map(\.name) } == [["Brick", "Munich Cycling"], ["FTP-Test 20 min", "Lockerer Lauf"]])
    #expect(weeks[0].totals.tss == 190)             // 100 + 90
    #expect(weeks[0].totals.durationMinutes == 210) // 90 + 120
    #expect(weeks[1].totals.tss == 80)              // nil TSS adds nothing
    #expect(weeks[1].totals.sessions == 2)
}

@MainActor
@Test func sportFilter_listsMultisportWholeButCountsOnlyItsLegs() {
    let weeks = ActivityList.weeks(sample(), sport: .run, query: "")
    #expect(weeks.map { $0.items.map(\.name) } == [["Brick"], ["Lockerer Lauf"]])
    #expect(weeks[0].totals.tss == 40)
    #expect(weeks[0].totals.distanceKm == 10)
    #expect(weeks[0].totals.durationMinutes == 30)
    #expect(weeks[1].totals.distanceKm == 8)
}

@MainActor
@Test func search_needsEveryWordCaseInsensitive() {
    #expect(ActivityList.weeks(sample(), sport: nil, query: "ftp").flatMap(\.items).map(\.name) == ["FTP-Test 20 min"])
    #expect(ActivityList.weeks(sample(), sport: nil, query: "munich RUN").isEmpty)
    #expect(ActivityList.weeks(sample(), sport: nil, query: "brick run").flatMap(\.items).map(\.name) == ["Brick"])
}
