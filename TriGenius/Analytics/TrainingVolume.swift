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

    /// The app's one week policy — ISO weeks (Monday-first, week 1 holds the first
    /// Thursday) regardless of locale — over `base`'s time zone. Every week bucket,
    /// week number and week-unit chart axis goes through this, never a bare `Calendar`.
    nonisolated static func weekCalendar(_ base: Calendar = .current) -> Calendar {
        var cal = base
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        return cal
    }

    /// Start of the Monday-week containing `date`.
    nonisolated static func weekStart(of date: Date, calendar: Calendar = .current) -> Date {
        let cal = weekCalendar(calendar)
        return cal.dateInterval(of: .weekOfYear, for: date)?.start
            ?? cal.startOfDay(for: date)
    }

    /// The `weeks` most recent Monday-weeks, ascending (oldest → current).
    static func recentWeekStarts(weeks: Int = 6, today: Date = Date()) -> [Date] {
        let cal = Calendar.current
        let current = weekStart(of: today)
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
        let starts = recentWeekStarts(weeks: weeks, today: today)
        guard let earliest = starts.first else { return [] }

        var acc: [Date: [SportFamily: VolumeTotals]] = [:]
        for s in starts { acc[s] = [:] }

        for record in records where record.date >= earliest {
            let ws = weekStart(of: record.date)
            guard acc[ws] != nil else { continue } // outside the window
            // A multisport session contributes to each discipline it contains, so a
            // brick counts as one bike *and* one run session.
            for c in record.sportContributions {
                var totals = acc[ws]?[c.family] ?? VolumeTotals()
                totals.tss += c.tss
                totals.distanceKm += c.distanceKm
                totals.durationMinutes += c.durationMinutes
                totals.sessions += 1
                acc[ws]?[c.family] = totals
            }
        }

        return starts.map { WeekBucket(weekStart: $0, totals: acc[$0] ?? [:]) }
    }
}
