import Foundation

// MARK: - ATP periodization (pure)
//
// Lays the period blocks across the season backward from each A event, inserts the
// recovery cadence and marks taper weeks. Sport-agnostic, no TSS yet — that's the
// engine's job. Output is one shell per week, season start → last event (+ a short
// transition tail).

/// One week's period placement, before any TSS is assigned.
struct ATPWeekShell: Sendable {
    let weekStart: Date          // Monday, start of day
    let period: ATPPeriod
    let periodWeekIndex: Int     // 1-based within the contiguous run of this period
    let isRecovery: Bool
    let isTaper: Bool
    let weeksToNextEvent: Int?
    let nextEventID: String?
}

enum ATPPeriodization {

    /// Lay out the season's weeks. Empty when there's nothing to periodize toward
    /// (no A/B event). C events are ignored entirely.
    static func layout(params: ATPParams, events: [ATPEventInput], today: Date = Date()) -> [ATPWeekShell] {
        let cal = Calendar.current
        let anchors = events.filter { $0.priority != .c }.sorted { $0.date < $1.date }
        guard let lastEvent = anchors.last else { return [] }

        let firstWeek = TrainingVolume.weekStart(of: params.startDate)
        let lastEventWeek = TrainingVolume.weekStart(of: lastEvent.date)
        guard lastEventWeek >= firstWeek,
              let horizon = cal.date(byAdding: .weekOfYear, value: ATPConstants.transitionWeeks, to: lastEventWeek)
        else { return [] }

        // Week-start Mondays, ascending, season start → transition tail.
        var weeks: [Date] = []
        var w = firstWeek
        while w <= horizon {
            weeks.append(w)
            guard let next = cal.date(byAdding: .weekOfYear, value: 1, to: w) else { break }
            w = next
        }
        let n = weeks.count
        guard n > 0 else { return [] }

        func weekIndex(of date: Date) -> Int? {
            weeks.firstIndex(of: TrainingVolume.weekStart(of: date))
        }

        // Period assignment: A events drive the ladder backward; each block is bounded
        // below by the previous A event's transition end. Default transition fills any
        // gap (pre-first-event tail handled by the first ladder reaching index 0).
        let recoveryCycle = max(2, params.recoveryCycle)
        var period = [ATPPeriod](repeating: .transition, count: n)
        var blockStart = 0
        for ev in anchors where ev.priority == .a {
            guard let e = weekIndex(of: ev.date) else { continue }
            assignLadder(into: &period, eventWeek: e, lowerBound: blockStart, recoveryCycle: recoveryCycle)
            let transEnd = min(e + ATPConstants.transitionWeeks, n - 1)
            if e + 1 <= transEnd { for i in (e + 1)...transEnd { period[i] = .transition } }
            blockStart = transEnd + 1
        }

        // Last index of each week's contiguous same-period run — recovery weeks land at
        // the block end (offset 0), then every `recoveryCycle` weeks backward, so even a
        // stretched Base 1 stays on cadence and always ends on a recovery week.
        var blockEnd = [Int](repeating: n - 1, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            blockEnd[i] = (i == n - 1 || period[i] != period[i + 1]) ? i : blockEnd[i + 1]
        }

        // Flags + per-period week index.
        var shells: [ATPWeekShell] = []
        var runIndex = 0
        for i in 0..<n {
            let p = period[i]
            if i > 0 && period[i - 1] == p { runIndex += 1 } else { runIndex = 0 }

            let isTaper = anchors.contains { ev in
                guard let e = weekIndex(of: ev.date) else { return false }
                let t = ATPConstants.taperWeeks(ev.priority)
                return t > 0 && i <= e && i > e - t        // the t weeks ending at (incl.) the event
            }
            let isRecovery = p.isBaseOrBuild && !isTaper && (blockEnd[i] - i) % recoveryCycle == 0

            let next = anchors.first { (weekIndex(of: $0.date) ?? -1) >= i }
            let weeksToNext = next.flatMap { weekIndex(of: $0.date) }.map { $0 - i }

            shells.append(ATPWeekShell(
                weekStart: weeks[i], period: p, periodWeekIndex: runIndex + 1,
                isRecovery: isRecovery, isTaper: isTaper,
                weeksToNextEvent: weeksToNext, nextEventID: next?.id))
        }
        return shells
    }

    /// Assign the ladder backward from `eventWeek`, never below `lowerBound`. Base/build
    /// blocks span one `recoveryCycle`. Run-in shorter than the ladder drops base blocks
    /// first; a longer one extends Base 1.
    private static func assignLadder(into period: inout [ATPPeriod], eventWeek: Int, lowerBound lb: Int, recoveryCycle: Int) {
        var idx = eventWeek
        for p in ATPConstants.ladder {
            let len = ATPConstants.ladderWeeks(p, recoveryCycle: recoveryCycle)
            var taken = 0
            while taken < len && idx >= lb {
                period[idx] = p
                idx -= 1; taken += 1
            }
            if idx < lb { break }
        }
        while idx >= lb { period[idx] = .base1; idx -= 1 }   // surplus extends the foundation
    }
}
