import Foundation

// MARK: - Tissue Load card model (display bridge)
//
// Turns forecasts, conflicts and the week's plan into the card's three rows, its day
// header and its closing row. Every string the card shows is produced here, so the
// view stays a renderer and the wording stays testable.

nonisolated struct TissueCardDay: Identifiable, Sendable {
    let date: Date
    /// Single localized weekday initial.
    let letter: String
    /// Nil on a rest day — the column then shows no dot.
    let sport: SportFamily?
    let isKey: Bool
    let isRace: Bool
    let isToday: Bool

    var id: Date { date }
}

nonisolated struct TissueCardRow: Identifiable, Sendable {
    let group: TissueGroup
    let days: [TissueDayState]
    /// "Now", "Tue", "Wed–Thu" — the row's primary value.
    let clearLabel: String
    /// Which tissue sets that forecast: "Achilles", "tendon" or "muscle".
    let caption: String
    let captionKind: TissueKind
    /// Index into `days` of the conflicting session's morning, if any.
    let conflictDay: Int?
    /// "Tue run", under the forecast, naming what the conflict is with.
    let conflictCaption: String?

    var id: TissueGroup { group }
}

/// The card's last row: what is free today, and the step that follows from it — asking
/// the coach to plan a session for exactly that.
nonisolated struct TissueCardClosingRow: Sendable {
    let title: String
    let subtitle: String
    /// Prefilled into the chat, built from the same state the card shows.
    let coachPrompt: String
}

nonisolated struct TissueCardModel: Sendable {
    let lead: TissueLeadLine
    let days: [TissueCardDay]
    let rows: [TissueCardRow]
    let closing: TissueCardClosingRow

    struct Input: Sendable {
        var forecasts: [TissueForecast]
        var conflicts: [TissueConflict]
        /// The next 7 days of plan, used for the header dots and the taper fill.
        var planned: [PlannedSession]
        var nextKeySession: PlannedSession?
        var previouslyListed: [TissueGroup]
        var period: ATPPeriod?
        var sessionCount: Int
        /// Sessions already done in the window, for the detail view's "caused it" rows.
        var drivers: [TissueDriver] = []
        var today: Date
    }

    static func make(_ input: Input, calendar: Calendar = .current, locale: Locale = .current) -> TissueCardModel {
        let listed = TissueLogic.cardRows(forecasts: input.forecasts, conflicts: input.conflicts,
                                          nextKeySession: input.nextKeySession,
                                          previouslyListed: input.previouslyListed)
        let byGroup = Dictionary(input.forecasts.map { ($0.group, $0) }, uniquingKeysWith: { first, _ in first })
        let startOfToday = calendar.startOfDay(for: input.today)

        let initials = DateFormatter()
        initials.locale = locale
        initials.calendar = calendar
        initials.setLocalizedDateFormatFromTemplate("EEEEE")

        let short = DateFormatter()
        short.locale = locale
        short.calendar = calendar
        short.setLocalizedDateFormatFromTemplate("EEE")

        func offset(of date: Date) -> Int {
            calendar.dateComponents([.day], from: startOfToday, to: calendar.startOfDay(for: date)).day ?? 0
        }

        let days = (-TissueMetrics.pastDays..<TissueMetrics.aheadDays).map { day -> TissueCardDay in
            let date = calendar.date(byAdding: .day, value: day, to: startOfToday) ?? startOfToday
            // A past day shows what was done; from today on the headline session, a key
            // one always winning the dot.
            let sessions = input.planned.filter { offset(of: $0.date) == day }
            let headline = sessions.first(where: \.isKey) ?? sessions.first
            return TissueCardDay(date: date,
                                 letter: initials.string(from: date),
                                 sport: day < 0 ? input.drivers.first { offset(of: $0.date) == day }?.sport : headline?.sport,
                                 isKey: headline?.isKey ?? false,
                                 isRace: headline?.id == input.nextKeySession?.id && input.period == .race,
                                 isToday: day == 0)
        }

        let rows = listed.compactMap { group -> TissueCardRow? in
            guard let forecast = byGroup[group], let today = forecast.today else { return nil }
            let conflict = input.conflicts.first { $0.group == group }
            let kind = today.governing
            return TissueCardRow(
                group: group,
                days: Array(forecast.afterTraining.prefix(TissueMetrics.dayCount)),
                clearLabel: TissueLogic.clearLabel(TissueLogic.clearDay(forecast), today: input.today,
                                                   calendar: calendar, locale: locale),
                caption: kind == .tendon ? (group.tendonLabel ?? "tendon") : "muscle",
                captionKind: kind,
                conflictDay: conflict.map { offset(of: $0.session.date) + forecast.todayIndex },
                conflictCaption: conflict.map {
                    "\(short.string(from: $0.session.date)) \($0.session.sport.displayName.lowercased())"
                })
        }

        return TissueCardModel(lead: TissueLeadLine.make(conflicts: input.conflicts,
                                                         forecasts: input.forecasts,
                                                         listed: listed,
                                                         period: input.period,
                                                         nextKeySession: input.nextKeySession,
                                                         hasEnduranceThisWeek: input.planned.contains { $0.sport != .strength },
                                                         sessionCount: input.sessionCount,
                                                         calendar: calendar, locale: locale),
                               days: days,
                               rows: rows,
                               closing: closingRow(input, listed: listed, calendar: calendar, locale: locale))
    }

    // MARK: Closing row

    private static func closingRow(_ input: Input, listed: [TissueGroup],
                                   calendar: Calendar, locale: Locale) -> TissueCardClosingRow {
        let free = TissueLogic.freeGroups(forecasts: input.forecasts, listed: listed)
        let total = input.forecasts.count
        let prompt = coachPrompt(input.forecasts)
        // In a taper the listed rows are clear too — they are there to show what the
        // next key session will load, not because anything is blocked.
        let everythingClear = input.forecasts.allSatisfy { $0.today?.governingLevel.isClear ?? false }

        if everythingClear {
            let subtitle: String
            if let race = input.nextKeySession, input.period == .race || input.period == .peak {
                let short = DateFormatter()
                short.locale = locale
                short.calendar = calendar
                short.setLocalizedDateFormatFromTemplate("EEE")
                subtitle = "Race \(short.string(from: race.date)) · rows show what the race will load"
            } else {
                subtitle = "All \(total) groups clear"
            }
            return TissueCardClosingRow(title: "Free: all \(total) groups", subtitle: subtitle, coachPrompt: prompt)
        }

        // Name what fits, count the rest — the card never ellipsizes a list of groups.
        // Upper body first: when the rows above say the legs are out, those are the
        // groups the athlete can actually act on today.
        let ordered = free.sorted {
            $0.isLowerBody != $1.isLowerBody ? !$0.isLowerBody : $0.anatomicalRank < $1.anatomicalRank
        }
        let named = ordered.prefix(3).map(\.label)
        let remaining = free.count - named.count
        let title = named.isEmpty ? "No group is clear today" : "Free: \(named.joined(separator: ", "))"
        let subtitle = remaining > 0 ? "+\(remaining) more clear"
                                     : "\(total - free.count) of \(total) groups carrying load"
        return TissueCardClosingRow(title: title, subtitle: subtitle, coachPrompt: prompt)
    }

    /// "Plan me a session for today that trains my upper back and shoulders and spares
    /// my calves." — every group clear this morning against every one that isn't.
    private static func coachPrompt(_ forecasts: [TissueForecast]) -> String {
        let clear = forecasts.filter { $0.today?.governingLevel.isClear ?? false }.map(\.group)
        let loaded = forecasts.map(\.group).filter { !clear.contains($0) }
        func names(_ groups: [TissueGroup]) -> String {
            let words = groups.sorted { $0.anatomicalRank < $1.anatomicalRank }.map { $0.label.lowercased() }
            return words.count > 1 ? words.dropLast().joined(separator: ", ") + " and " + words.last! : words.joined()
        }
        guard !clear.isEmpty else { return "No muscle group is clear today. What can I still train?" }
        guard !loaded.isEmpty else { return "Every muscle group is clear today. Plan me a session for today." }
        return "Plan me a session for today that trains my \(names(clear)) and spares my \(names(loaded))."
    }
}

// MARK: - 6-week mode (chronic)
//
// A different question from fatigue: which groups the plan has been neglecting or
// overloading for weeks. Under-target and over-target are opposite directions around
// a target band, so this view diverges where the 7-day one ramps.

nonisolated struct TissueChronicRow: Identifiable, Sendable {
    let group: TissueGroup
    let weeks: [ChronicWeek]
    let status: ChronicStatus
    /// "6 of 6 wk" — weeks counted, never a percentage.
    let statusDetail: String

    var id: TissueGroup { group }
}

nonisolated struct TissueChronicModel: Sendable {
    let lead: String
    /// Hands the finding to the coach. Nil when nothing is off target.
    let action: String?
    /// The question that action asks the coach.
    let coachPrompt: String?
    /// One label per week column, empty except where the month changes.
    let monthLabels: [String]
    let rows: [TissueChronicRow]

    /// The window the chronic view needs before it says anything at all.
    static let requiredWeeks = 6

    /// Nil until there is enough history — the mode stays hidden rather than guessing.
    static func make(history: [TissueGroup: [ChronicWeek]],
                     calendar: Calendar = .current, locale: Locale = .current) -> TissueChronicModel? {
        let complete = history.filter { $0.value.count >= requiredWeeks }
        guard !complete.isEmpty else { return nil }

        let listed = TissueLogic.chronicRows(complete)
        let rows = listed.compactMap { group -> TissueChronicRow? in
            guard let weeks = complete[group] else { return nil }
            let status = TissueLogic.chronicStatus(weeks)
            return TissueChronicRow(group: group, weeks: weeks, status: status,
                                    statusDetail: "\(status.weeksOffTarget) of \(weeks.count) wk")
        }

        let months = DateFormatter()
        months.locale = locale
        months.calendar = calendar
        months.setLocalizedDateFormatFromTemplate("MMM")
        let timeline = rows.first?.weeks ?? complete.values.first ?? []
        var lastMonth: Int?
        let labels = timeline.map { week -> String in
            let month = calendar.component(.month, from: week.weekStart)
            defer { lastMonth = month }
            return month == lastMonth ? "" : months.string(from: week.weekStart)
        }

        guard let top = rows.first else {
            return TissueChronicModel(lead: "Every group is on target.", action: nil,
                                      coachPrompt: nil, monthLabels: labels, rows: [])
        }
        let direction = top.status.word.lowercased()
        let name = top.group.label.lowercased()
        let weeks = top.status.weeksOffTarget
        let isUnder = top.status == .under(weeks: weeks)
        return TissueChronicModel(
            lead: "\(top.group.label) \(direction) target for \(weeks) weeks.",
            action: isUnder ? "Ask coach to add \(name) work" : "Ask coach about \(name) load",
            coachPrompt: isUnder
                ? "My \(name) have been under target for \(weeks) weeks. Can you add work for them?"
                : "My \(name) have been over target for \(weeks) weeks. Should I pull back?",
            monthLabels: labels,
            rows: rows)
    }
}
