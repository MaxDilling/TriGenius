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
// Note: CTL needs a long warm-up (>42 days) to be meaningful. We therefore
// compute over ALL available history but only return the last 6 weeks for the
// UI. Deeper historical backfill (e.g. via the `garmin-health-data` lib) will
// improve early-history accuracy.

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
    /// Last 6 weeks (42 days), ascending — for charting.
    let points: [PMCPoint]
    /// Most recent day's values.
    let snapshot: PMCSnapshot?
}

enum PMCEngine {

    static let ctlTimeConstant = 42.0
    static let atlTimeConstant = 7.0

    /// Number of trailing days to expose to the UI (6 weeks).
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
            return PMCResult(points: [], snapshot: nil)
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
        let trimmed = Array(points.suffix(displayDays))
        return PMCResult(points: trimmed, snapshot: snapshot)
    }

    /// Convenience: read the local store and compute the current PMC.
    @MainActor
    static func current(
        store: TrainingDataStore? = nil,
        today: Date = Date(),
        historyDays: Int = 365
    ) -> PMCResult {
        let store = store ?? .shared
        let cal = Calendar.current
        let to = today
        let from = cal.date(byAdding: .day, value: -historyDays, to: today) ?? today
        let daily = store.dailyTSS(from: from, to: to)
        return compute(dailyTSS: daily, today: today)
    }
}
