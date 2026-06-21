import Foundation

// MARK: - Performance Management Chart (PMC) Engine
//
// GOAL.md: compute CTL (Fitness, 42-day EWMA), ATL (Fatigue, 7-day EWMA) and
// TSB (Form) from the daily TSS stored in the local database.
//
// Standard TrainingPeaks model, exponentially-weighted moving averages:
//   CTL_today = CTL_yest + (TSS_today − CTL_yest) · (1 − e^(−1/42))
//   ATL_today = ATL_yest + (TSS_today − ATL_yest) · (1 − e^(−1/7))
//   TSB_today = CTL_yest − ATL_yest        (Form = yesterday's fitness − fatigue)
//
// Note: CTL needs a long warm-up (>42 days) to be meaningful. We compute over
// ALL available history and return the full series; callers slice the window
// they need. Deeper historical backfill (e.g. via the `garmin-health-data` lib)
// will improve early-history accuracy.

struct PMCPoint: Identifiable, Sendable {
    let date: Date
    let ctl: Double   // Fitness
    let atl: Double   // Fatigue
    let tsb: Double   // Form
    var id: Date { date }
}

struct PMCSnapshot: Sendable {
    let date: Date
    let ctl: Double
    let atl: Double
    let tsb: Double
}

struct PMCResult: Sendable {
    /// The full computed history, ascending — callers slice the range they need
    /// (the dashboard shows the last weeks; the detail view offers 30D/90D/1Y).
    let points: [PMCPoint]
    /// TrainingPeaks-style forward projection: CTL / ATL / TSB continued past
    /// today from planned-but-not-yet-completed workouts, ascending (one point per
    /// day after today). Empty when nothing is scheduled ahead. Rendered as a
    /// faded/dashed continuation of the historic curve.
    let forecast: [PMCPoint]
    /// Most recent day's values.
    let snapshot: PMCSnapshot?

    /// The value `days` ago (closest point at/before that date), for deltas.
    func value(daysAgo days: Int, _ metric: (PMCPoint) -> Double) -> Double? {
        guard let last = points.last else { return nil }
        let cal = Calendar.current
        guard let target = cal.date(byAdding: .day, value: -days, to: last.date) else { return nil }
        return points.last(where: { $0.date <= target }).map(metric)
    }
}

enum PMCEngine {

    static let ctlTimeConstant = 42.0
    static let atlTimeConstant = 7.0

    /// Trailing window the main dashboard summarises (6 weeks).
    static let displayDays = 42

    /// Pure computation. `dailyTSS` may have gaps; missing days count as 0 TSS.
    static func compute(dailyTSS: [DailyTSS], today: Date = Date()) -> PMCResult {
        let cal = Calendar.current
        let endDay = cal.startOfDay(for: today)

        // Map day → total TSS for O(1) lookup.
        var byDay: [Date: Double] = [:]
        for d in dailyTSS {
            byDay[cal.startOfDay(for: d.date), default: 0] += d.totalTSS
        }

        guard let firstActivityDay = byDay.keys.min() else {
            return PMCResult(points: [], forecast: [], snapshot: nil)
        }
        // Start at least the CTL warm-up window before the first activity so the
        // EWMA settles, but never after the first activity day.
        let startDay = min(firstActivityDay, endDay)

        let aCTL = 1 - exp(-1 / ctlTimeConstant)
        let aATL = 1 - exp(-1 / atlTimeConstant)

        var ctl = 0.0
        var atl = 0.0
        var points: [PMCPoint] = []

        var day = startDay
        while day <= endDay {
            let tss = byDay[day] ?? 0
            // Form is yesterday's fitness − fatigue (values before today's update).
            let tsb = ctl - atl
            ctl += (tss - ctl) * aCTL
            atl += (tss - atl) * aATL
            points.append(PMCPoint(date: day, ctl: ctl, atl: atl, tsb: tsb))
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        let snapshot = points.last.map {
            PMCSnapshot(date: $0.date, ctl: $0.ctl, atl: $0.atl, tsb: $0.tsb)
        }
        return PMCResult(points: points, forecast: [], snapshot: snapshot)
    }

    // MARK: - Forward projection

    /// How far ahead the forecast runs by default (6 weeks — beyond that the EWMA
    /// of a static plan is no longer informative and most plans aren't scheduled).
    static let forecastDays = 42

    /// Continue the PMC forward from the last historic point using the planned
    /// (not-yet-completed) TSS per future day. Pure. Returns one point per day
    /// from today+1 through the last planned day (capped at `maxHorizonDays`);
    /// empty when nothing is planned ahead. Today itself stays in the historic
    /// series (it already carries actual TSS), so projection starts at today+1 to
    /// avoid double-counting a session that is both planned and partly done.
    static func project(
        history points: [PMCPoint],
        plannedByDay: [Date: Double],
        today: Date = Date(),
        maxHorizonDays: Int = forecastDays
    ) -> [PMCPoint] {
        guard let last = points.last else { return [] }
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: today)
        let futurePlanned = plannedByDay.filter { $0.key > startDay && $0.value > 0 }
        guard let lastPlanned = futurePlanned.keys.max() else { return [] }
        let horizonCap = cal.date(byAdding: .day, value: maxHorizonDays, to: startDay) ?? lastPlanned
        let endDay = min(lastPlanned, horizonCap)

        let aCTL = 1 - exp(-1 / ctlTimeConstant)
        let aATL = 1 - exp(-1 / atlTimeConstant)
        var ctl = last.ctl
        var atl = last.atl
        var forecast: [PMCPoint] = []

        guard var day = cal.date(byAdding: .day, value: 1, to: startDay) else { return [] }
        while day <= endDay {
            let tss = plannedByDay[day] ?? 0
            let tsb = ctl - atl
            ctl += (tss - ctl) * aCTL
            atl += (tss - atl) * aATL
            forecast.append(PMCPoint(date: day, ctl: ctl, atl: atl, tsb: tsb))
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return forecast
    }

    /// Total planned TSS per future day, derived from scheduled workouts. TSS is
    /// taken verbatim when the source set it, else estimated from the planned
    /// duration (same rule the weekly targets use).
    @MainActor
    static func plannedTSSByDay(_ scheduled: [ScheduledWorkoutRecord]) -> [Date: Double] {
        let cal = Calendar.current
        var byDay: [Date: Double] = [:]
        for w in scheduled {
            let family = SportFamily(sportKey: w.sport)
            let tss = w.targetTSS ?? WeeklyTargets.estimatedTSS(family: family, minutes: w.targetDurationMinutes)
            byDay[cal.startOfDay(for: w.date), default: 0] += tss
        }
        return byDay
    }

    /// Convenience: read the local store and compute the current PMC, including
    /// the forward projection from upcoming planned workouts. Pass
    /// `forecastDays: 0` to skip the (slightly more expensive) projection.
    @MainActor
    static func current(
        store: TrainingDataStore? = nil,
        today: Date = Date(),
        historyDays: Int = 365,
        forecastDays: Int = forecastDays
    ) -> PMCResult {
        let store = store ?? .shared
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -historyDays, to: today) ?? today
        let daily = store.dailyTSS(from: from, to: today)
        let result = compute(dailyTSS: daily, today: today)

        guard forecastDays > 0 else { return result }
        let startDay = cal.startOfDay(for: today)
        let to = cal.date(byAdding: .day, value: forecastDays, to: startDay) ?? startDay
        let scheduled = store.scheduledWorkouts(from: startDay, to: to)
        let forecast = project(
            history: result.points,
            plannedByDay: plannedTSSByDay(scheduled),
            today: today,
            maxHorizonDays: forecastDays
        )
        return PMCResult(points: result.points, forecast: forecast, snapshot: result.snapshot)
    }
}
