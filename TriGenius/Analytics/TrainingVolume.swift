import Foundation

// MARK: - Training Volume
//
// Weekly aggregation of stored activities per sport family — the data behind the
// dashboard's "volume per discipline" section. Source-agnostic: it reads
// `WorkoutRecord`s and classifies them via `SportFamily`, and reads TSS through
// the `TSS` abstraction.
//
// Weeks run Monday→Sunday. We expose the current week plus the previous 5
// (6 buckets total), matching the ~6-week window that meaningfully feeds CTL.

struct VolumeTotals: Sendable {
    var tss: Double = 0
    var distanceKm: Double = 0
    var durationMinutes: Double = 0
    var sessions: Int = 0
}

enum TrainingVolume {

    struct WeekBucket: Identifiable, Sendable {
        let weekStart: Date
        let totals: [SportFamily: VolumeTotals]
        var id: Date { weekStart }

        func totals(for family: SportFamily) -> VolumeTotals {
            totals[family] ?? VolumeTotals()
        }
    }

    /// A Monday-first calendar so week buckets are stable regardless of locale.
    private static var weekCalendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = 2 // Monday
        return cal
    }

    /// Start of the Monday-week containing `date`.
    static func weekStart(of date: Date, calendar: Calendar? = nil) -> Date {
        let cal = calendar ?? weekCalendar
        return cal.dateInterval(of: .weekOfYear, for: date)?.start
            ?? cal.startOfDay(for: date)
    }

    /// The `weeks` most recent Monday-weeks, ascending (oldest → current).
    static func recentWeekStarts(weeks: Int = 6, today: Date = Date()) -> [Date] {
        let cal = weekCalendar
        let current = weekStart(of: today, calendar: cal)
        return (0..<weeks).reversed().compactMap {
            cal.date(byAdding: .weekOfYear, value: -$0, to: current)
        }
    }

    /// Aggregate `records` into the last `weeks` weekly buckets per sport family.
    @MainActor
    static func weeklyBuckets(
        records: [WorkoutRecord],
        weeks: Int = 6,
        today: Date = Date()
    ) -> [WeekBucket] {
        let cal = weekCalendar
        let starts = recentWeekStarts(weeks: weeks, today: today)
        guard let earliest = starts.first else { return [] }

        var acc: [Date: [SportFamily: VolumeTotals]] = [:]
        for s in starts { acc[s] = [:] }

        for record in records where record.date >= earliest {
            let ws = weekStart(of: record.date, calendar: cal)
            guard acc[ws] != nil else { continue } // outside the window
            let family = SportFamily(sportKey: record.sport)
            var totals = acc[ws]?[family] ?? VolumeTotals()
            totals.tss += TSS.value(for: record) ?? 0
            totals.distanceKm += record.distanceKm
            totals.durationMinutes += record.durationMinutes
            totals.sessions += 1
            acc[ws]?[family] = totals
        }

        return starts.map { WeekBucket(weekStart: $0, totals: acc[$0] ?? [:]) }
    }
}
