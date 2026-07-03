import Foundation

// MARK: - Fitness ramp rate
//
// Weekly CTL change from the PMC series — the TrainingPeaks "CTL gained per week"
// build metric. Distinct from `TrainingLoadAnalytics`' per-sport *volume* ramp
// (current week vs trailing-3-week mean); the two must never share a name.

struct RampWeek: Identifiable, Sendable, Codable, Equatable {
    let weekStart: Date       // Monday
    let ctlStart: Double      // CTL at the last point before weekStart
    let ctlEnd: Double        // CTL at the last point inside the week
    var delta: Double { ctlEnd - ctlStart }
    var id: Date { weekStart }
}

enum RampRate {

    /// TrainingPeaks safe build band, CTL gained per week.
    static let safeBand: ClosedRange<Double> = 5.0...8.0

    /// Weekly CTL change over the `weeks` most recent Monday-weeks, ascending,
    /// from an ascending PMC series. Weeks without a pre-week baseline point are
    /// omitted (no fabricated zero start); the in-progress week's `ctlEnd` is
    /// the latest available point.
    static func weeklySeries(points: [PMCPoint], weeks: Int, today: Date = Date()) -> [RampWeek] {
        guard !points.isEmpty else { return [] }
        let cal = Calendar.current
        return TrainingVolume.recentWeekStarts(weeks: weeks, today: today).compactMap { weekStart in
            guard let nextWeekStart = cal.date(byAdding: .weekOfYear, value: 1, to: weekStart),
                  let start = points.last(where: { $0.date < weekStart }),
                  let end = points.last(where: { $0.date < nextWeekStart }),
                  end.date >= weekStart
            else { return nil }
            return RampWeek(weekStart: weekStart, ctlStart: start.ctl, ctlEnd: end.ctl)
        }
    }
}
