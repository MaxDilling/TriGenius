import Foundation

// MARK: - Tissue Load rules (pure)
//
// The forecast label and the card's row selection. Every rule here is computed —
// none of it is the coach's judgement. Conflicts come from `TissueLoadModel`.

nonisolated enum TissueLogic {

    // MARK: Clear forecast — the primary value of every row, region and cell

    /// Days from today until the group is clear for hard work (0 = today). Nil when it
    /// doesn't clear inside the window.
    static func clearDay(_ forecast: TissueForecast) -> Int? {
        forecast.ahead.firstIndex { $0.governingLevel.isClear }.map { $0 - forecast.todayIndex }
    }

    /// "Now", "Tue" — or "Later" outside the window.
    static func clearLabel(_ day: Int?, today: Date,
                           calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let day else { return "Later" }
        guard day != 0 else { return "Now" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: calendar.date(byAdding: .day, value: day, to: today) ?? today)
    }

    // MARK: Card rows

    /// The card's three rows: conflicts first, then the groups that aren't clear with
    /// the latest clear date first, then — in a taper or rest week — what the next key
    /// (heaviest planned) session will load. Ties fall back to anatomical order.
    ///
    /// `previouslyListed` is what keeps the card still: a group shown yesterday stays
    /// until it clears, even when another group now outranks it.
    static func cardRows(forecasts: [TissueForecast], conflicts: [TissueConflict],
                         nextKeySession: PlannedSession?, previouslyListed: [TissueGroup],
                         limit: Int = 3) -> [TissueGroup] {
        let byGroup = Dictionary(forecasts.map { ($0.group, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [TissueGroup] = []
        func push(_ group: TissueGroup) {
            guard !rows.contains(group), rows.count < limit else { return }
            rows.append(group)
        }

        for conflict in conflicts { push(conflict.group) }

        for group in previouslyListed {
            guard let today = byGroup[group]?.today, !today.governingLevel.isClear else { continue }
            push(group)
        }

        let notClear = forecasts.filter { !($0.today?.governingLevel.isClear ?? true) }
        let ranked = notClear.sorted {
            let a = clearDay($0) ?? Int.max, b = clearDay($1) ?? Int.max
            return a != b ? a > b : $0.group.anatomicalRank < $1.group.anatomicalRank
        }
        ranked.forEach { push($0.group) }

        if let next = nextKeySession {
            next.loads.sorted { $0.anatomicalRank < $1.anatomicalRank }.forEach(push)
        }
        return rows
    }

    /// The card's free row: clear today and not already listed above.
    static func freeGroups(forecasts: [TissueForecast], listed: [TissueGroup]) -> [TissueGroup] {
        forecasts
            .filter { !listed.contains($0.group) && ($0.today?.governingLevel.isClear ?? false) }
            .map(\.group)
            .sorted { $0.anatomicalRank < $1.anatomicalRank }
    }

    // MARK: Chronic status

    /// The groups furthest from their target band, most weeks off target first, ties
    /// in anatomical order. Groups inside the band are not listed: the chronic view is
    /// about neglect and overuse, and "on target" is neither.
    static func chronicRows(_ history: [TissueGroup: [ChronicWeek]], limit: Int = 3) -> [TissueGroup] {
        var ranked: [(group: TissueGroup, weeks: Int)] = []
        for (group, weeks) in history {
            let off = chronicStatus(weeks).weeksOffTarget
            if off > 0 { ranked.append((group, off)) }
        }
        ranked.sort { $0.weeks != $1.weeks ? $0.weeks > $1.weeks : $0.group.anatomicalRank < $1.group.anatomicalRank }
        return Array(ranked.prefix(limit).map(\.group))
    }

    static func chronicStatus(_ weeks: [ChronicWeek]) -> ChronicStatus {
        let under = weeks.filter { $0.deviation < 0 }.count
        let over = weeks.filter { $0.deviation > 0 }.count
        let half = max(1, weeks.count / 2)
        if under > half && under >= over { return .under(weeks: under) }
        if over > half { return .over(weeks: over) }
        return .onTarget
    }
}
