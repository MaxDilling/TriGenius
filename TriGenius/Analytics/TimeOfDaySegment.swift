import SwiftUI

// MARK: - Time-of-day availability
//
// FEATURES.md "Extended calendar — past workouts and daily life context": the
// calendar should make it obvious *where there is still time to train*. A total
// free-minutes score is misleading — fragmented free time is useless. Instead we
// split the day into a few coarse segments (morning / midday / evening) and, from
// the athlete's EventKit busy windows, report whether each one is COMPLETELY free.
//
// Pure model: no EventKit calls here. It consumes the `DayAvailability` /
// `BusyWindow` value types already produced by `CalendarService`.

/// A coarse part of the day. Boundaries are central constants so they're easy to
/// tune (and a natural home should the app gain a "Zentrale Konstanten" file).
enum TimeOfDaySegment: String, CaseIterable, Identifiable, Sendable {
    case morning, midday, evening

    var id: String { rawValue }

    // Segment boundaries as minutes after midnight.
    static let dayStartMinute = 6 * 60      // 06:00
    static let middayStartMinute = 12 * 60  // 12:00
    static let eveningStartMinute = 17 * 60 // 17:00
    static let dayEndMinute = 22 * 60       // 22:00

    /// Half-open minute range `[lower, upper)` this segment covers.
    var range: Range<Int> {
        switch self {
        case .morning: return Self.dayStartMinute..<Self.middayStartMinute
        case .midday: return Self.middayStartMinute..<Self.eveningStartMinute
        case .evening: return Self.eveningStartMinute..<Self.dayEndMinute
        }
    }

    /// Length of the segment in minutes.
    var lengthMinutes: Int { range.upperBound - range.lowerBound }

    /// Minute a workout dropped onto this segment is anchored to (its start).
    var anchorMinute: Int { range.lowerBound }

    var label: String {
        switch self {
        case .morning: return "Morning"
        case .midday: return "Midday"
        case .evening: return "Evening"
        }
    }

    /// The segment a minute-of-day falls into, if any (nil outside active hours).
    static func containing(minute: Int) -> TimeOfDaySegment? {
        allCases.first { $0.range.contains(minute) }
    }
}

/// How occupied a segment is. Only `.free` means a clear block to train in.
enum SegmentState: Sendable {
    case free        // no commitment overlaps the segment
    case partlyBusy  // some overlap, but a usable gap may remain
    case busy        // (almost) fully booked

    var color: Color {
        switch self {
        case .free: return .green
        case .partlyBusy: return .orange
        case .busy: return .red
        }
    }
}

/// Computes per-segment availability for a day from its busy windows.
enum DaySegments {
    /// A segment counts as `.busy` once this fraction of it is occupied.
    private static let busyThreshold = 0.8

    /// State per segment for one day. An all-day event marks every segment busy.
    static func states(for day: DayAvailability, calendar: Calendar = .current) -> [TimeOfDaySegment: SegmentState] {
        if day.allDay {
            return Dictionary(uniqueKeysWithValues: TimeOfDaySegment.allCases.map { ($0, .busy) })
        }

        // Busy intervals as minutes after the day's midnight, clipped to [0, 1440].
        let dayStart = calendar.startOfDay(for: day.date)
        let intervals: [(Int, Int)] = day.windows
            .filter { !$0.isAllDay }
            .map { w in
                let s = max(0, Int(w.start.timeIntervalSince(dayStart) / 60))
                let e = min(24 * 60, Int(w.end.timeIntervalSince(dayStart) / 60))
                return (s, e)
            }
            .filter { $0.1 > $0.0 }

        var out: [TimeOfDaySegment: SegmentState] = [:]
        for segment in TimeOfDaySegment.allCases {
            let lo = segment.range.lowerBound, hi = segment.range.upperBound
            let overlap = intervals.reduce(0) { acc, iv in
                acc + max(0, min(iv.1, hi) - max(iv.0, lo))
            }
            if overlap == 0 {
                out[segment] = .free
            } else if Double(overlap) >= Double(segment.lengthMinutes) * busyThreshold {
                out[segment] = .busy
            } else {
                out[segment] = .partlyBusy
            }
        }
        return out
    }
}
