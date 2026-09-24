import Foundation

// MARK: - Tissue Load grid model
//
// Every group, not just the three the card has room for, with the forecast's past days
// before today. Same inputs as the card, so the two can never disagree about a forecast.

nonisolated struct TissueGridModel: Sendable {
    let days: [TissueGridDay]
    let rows: [TissueGridRow]

    static func make(_ input: TissueCardModel.Input,
                     calendar: Calendar = .current, locale: Locale = .current) -> TissueGridModel {
        let startOfToday = calendar.startOfDay(for: input.today)
        let past = input.forecasts.first?.todayIndex ?? 0
        let first = calendar.date(byAdding: .day, value: -past, to: startOfToday) ?? startOfToday

        let letters = DateFormatter()
        letters.locale = locale
        letters.calendar = calendar
        letters.setLocalizedDateFormatFromTemplate("EEEEE")

        func offset(of date: Date) -> Int {
            calendar.dateComponents([.day], from: startOfToday, to: calendar.startOfDay(for: date)).day ?? 0
        }

        let days = (0..<TissueMetrics.dayCount).map { index -> TissueGridDay in
            let date = calendar.date(byAdding: .day, value: index, to: first) ?? first
            let day = index - past
            // A past day shows what was done, today and later what is planned.
            let done = input.drivers.first { offset(of: $0.date) == day }
            let sessions = input.planned.filter { offset(of: $0.date) == day }
            let headline = sessions.first(where: \.isKey) ?? sessions.first
            return TissueGridDay(date: date,
                                 letter: letters.string(from: date),
                                 dayNumber: "\(calendar.component(.day, from: date))",
                                 sport: day < 0 ? done?.sport : headline?.sport,
                                 isKey: headline?.isKey ?? false,
                                 isToday: day == 0)
        }

        // Latest to clear first — the order the athlete has to plan around. Ties keep
        // the anatomical order so rows never shuffle.
        let ordered = input.forecasts.sorted {
            let a = TissueLogic.clearDay($0) ?? Int.max
            let b = TissueLogic.clearDay($1) ?? Int.max
            return a != b ? a > b : $0.group.anatomicalRank < $1.group.anatomicalRank
        }

        let rows = ordered.map { forecast -> TissueGridRow in
            let conflict = input.conflicts.first { $0.group == forecast.group }
            return TissueGridRow(
                group: forecast.group,
                clearLabel: TissueLogic.clearLabel(TissueLogic.clearDay(forecast), today: input.today,
                                                   calendar: calendar, locale: locale),
                days: Array(forecast.afterTraining.prefix(TissueMetrics.dayCount)),
                conflictDay: conflict.map { offset(of: $0.session.date) + past })
        }
        return TissueGridModel(days: days, rows: rows)
    }
}
