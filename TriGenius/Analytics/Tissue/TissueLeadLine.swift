import Foundation

// MARK: - Tissue Load lead line
//
// The card's one-line headline. Computed from state against a fixed set of templates,
// never written by the model — the athlete acts on this sentence, so it has to say the
// same thing the rows below it show.
//
// Precedence, most decision-relevant first: a conflict outranks everything, then the
// warning that the estimates are still thin, then the taper, then today's advice.

nonisolated struct TissueLeadLine: Equatable, Sendable {
    enum Glyph: Equatable, Sendable { case conflict, taper }

    var text: String
    var glyph: Glyph?
    /// Only a conflict is a button — it opens the resolution sheet. The rest state facts.
    var opensConflict: Bool = false

    static func make(conflicts: [TissueConflict],
                     forecasts: [TissueForecast],
                     listed: [TissueGroup],
                     period: ATPPeriod?,
                     nextKeySession: PlannedSession?,
                     hasEnduranceThisWeek: Bool,
                     sessionCount: Int,
                     calendar: Calendar = .current,
                     locale: Locale = .current) -> TissueLeadLine {

        if let first = conflicts.first {
            let tissue = first.tissue == .tendon
                ? (first.group.tendonLabel ?? "Tendon")
                : first.group.label
            let day = weekday(first.session.date, calendar: calendar, locale: locale, style: .short)
            let sport = first.session.sport.displayName.lowercased()
            return TissueLeadLine(text: "\(day) \(sport): \(tissue) load spike.",
                                  glyph: .conflict, opensConflict: true)
        }

        if sessionCount < TissueConstants.minimumSessionsForAdvice {
            return TissueLeadLine(text: "Early estimates from \(sessionCount) sessions.")
        }

        if period == .peak || period == .race {
            guard let race = nextKeySession else {
                return TissueLeadLine(text: "Taper on track.", glyph: .taper)
            }
            let day = weekday(race.date, calendar: calendar, locale: locale, style: .full)
            return TissueLeadLine(text: "Taper on track. Clear for \(day).", glyph: .taper)
        }

        let states = forecasts.compactMap { forecast in forecast.today.map { (forecast.group, $0) } }
        let upper = states.filter { !$0.0.isLowerBody }
        // Tied to the rows, not to every leg group: the sentence has to say the same
        // thing the card shows, and a loaded adductor is not "legs today: no".
        let legsBlocked = !listed.isEmpty && listed.allSatisfy { group in
            group.isLowerBody && !(states.first { $0.0 == group }?.1.governingLevel.isClear ?? true)
        }

        if legsBlocked && !upper.isEmpty && upper.allSatisfy({ $0.1.governingLevel.isClear }) {
            return TissueLeadLine(text: "Legs today: no. Upper body: yes.")
        }

        if !hasEnduranceThisWeek {
            return TissueLeadLine(text: "Strength-only week. Legs are clear.")
        }

        switch period {
        case .build1, .build2: return TissueLeadLine(text: "Build week, on plan.")
        case .base1, .base2, .base3: return TissueLeadLine(text: "Base week, on plan.")
        default: return TissueLeadLine(text: "On plan.")
        }
    }

    private static func weekday(_ date: Date, calendar: Calendar, locale: Locale,
                                style: WeekdayStyle) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(style == .short ? "EEE" : "EEEE")
        formatter.calendar = calendar
        return formatter.string(from: date)
    }

    private enum WeekdayStyle { case short, full }
}
