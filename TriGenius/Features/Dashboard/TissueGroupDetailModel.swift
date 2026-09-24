import Foundation

// MARK: - Tissue Load group detail model
//
// One group's whole story: what state it is in, when it clears, what put it there and
// what is coming that will load it again. The explanation sentence is assembled from
// the same numbers the lanes draw — it is a template, not prose from the model.

nonisolated struct TissueGroupDetailModel: Sendable {
    /// A session before or after today, with what it means for this group.
    struct Row: Identifiable, Sendable {
        let id = UUID()
        /// "Sun 20 · Long run 24 km"
        let title: String
        /// "caused it", "key · clear by then", "key · load spike"
        let note: String
        let isWarning: Bool
        /// What the session puts on this group in model units ("M 42 · T 30") — a
        /// debugging aid while the constants are provisional.
        let load: String?
        /// The stored workout the row opens.
        let recordId: String?
    }

    let group: TissueGroup
    /// "Clear for hard running" — named after the next key session that loads the group.
    let clearCaption: String
    let clearLabel: String
    let days: [TissueGridDay]
    /// The grid's days after each day's sessions, as the lanes draw them.
    let states: [TissueDayState]
    /// This morning's state — the one the figure in the header draws and the prompt
    /// reasons from.
    let today: TissueDayState?
    /// The tendon lane's label ("Achilles"), nil when the group has no modelled tendon.
    let tendonLabel: String?
    let explanation: String
    let rows: [Row]

    /// The question handed to the chat, built from the numbers on screen so the coach
    /// starts from what the athlete is looking at.
    var coachPrompt: String {
        let name = group.label.lowercased()
        guard let today, !today.governingLevel.isClear else {
            return "My \(name) are clear. What should I train today?"
        }
        let tissue = today.governing == .tendon ? (tendonLabel ?? "tendon") : "muscle"
        return "My \(name) are loaded — \(tissue) clears \(clearLabel). What should I train today?"
    }

    static func make(group: TissueGroup, input: TissueCardModel.Input,
                     calendar: Calendar = .current, locale: Locale = .current) -> TissueGroupDetailModel? {
        guard let forecast = input.forecasts.first(where: { $0.group == group }) else { return nil }
        let grid = TissueGridModel.make(input, calendar: calendar, locale: locale)
        let states = Array(forecast.afterTraining.prefix(grid.days.count))
        let clearLabel = TissueLogic.clearLabel(TissueLogic.clearDay(forecast), today: input.today,
                                                calendar: calendar, locale: locale)

        let dayAndDate = DateFormatter()
        dayAndDate.locale = locale
        dayAndDate.calendar = calendar
        dayAndDate.setLocalizedDateFormatFromTemplate("EEE d")

        let weekday = DateFormatter()
        weekday.locale = locale
        weekday.calendar = calendar
        weekday.setLocalizedDateFormatFromTemplate("EEEE")

        let affecting = input.planned
            .filter { $0.loads.contains(group) && $0.date >= input.today }
            .sorted { $0.date < $1.date }
        let conflicting = Set(input.conflicts.filter { $0.group == group }.map(\.session.id))

        var rows = input.drivers
            .filter { $0.loads.contains(group) }
            .sorted { $0.date > $1.date }
            .map { Row(title: "\(dayAndDate.string(from: $0.date)) · \($0.title)",
                       note: "caused it", isWarning: false, load: load($0.dose[group]), recordId: $0.recordId) }

        rows += affecting.map { session in
            let note = session.isKey
                ? (conflicting.contains(session.id) ? "key · load spike" : "key · clear by then")
                : (conflicting.contains(session.id) ? "load spike" : "loads it again")
            return Row(title: "\(dayAndDate.string(from: session.date)) · \(session.title)",
                       note: note, isWarning: conflicting.contains(session.id),
                       load: load(session.dose[group]), recordId: session.recordId)
        }

        let sport = affecting.first(where: \.isKey)?.sport
        return TissueGroupDetailModel(
            group: group,
            clearCaption: clearCaption(for: sport),
            clearLabel: clearLabel,
            days: grid.days,
            states: states,
            today: forecast.today,
            tendonLabel: forecast.today?.tendon == nil ? nil : (group.tendonLabel ?? "Tendon"),
            explanation: explanation(forecast: forecast, group: group,
                                     drivers: input.drivers.filter { $0.loads.contains(group) },
                                     weekday: weekday, calendar: calendar),
            rows: rows)
    }

    /// Named after the discipline of the next key session that loads the group, so the
    /// forecast is phrased as the decision it unblocks.
    private static func clearCaption(for sport: SportFamily?) -> String {
        switch sport {
        case .run: return "Clear for hard running"
        case .bike: return "Clear for hard riding"
        case .swim: return "Clear for hard swimming"
        case .strength: return "Clear for heavy lifting"
        default: return "Clear for hard work"
        }
    }

    private static func load(_ dose: TissueDose?) -> String? {
        guard let dose, dose.total > 0 else { return nil }
        let muscle = "M \(Int(dose.muscle.rounded()))"
        return dose.tendon > 0 ? "\(muscle) · T \(Int(dose.tendon.rounded()))" : muscle
    }

    /// Why the forecast reads the way it does, from the same numbers the lanes draw.
    private static func explanation(forecast: TissueForecast, group: TissueGroup, drivers: [TissueDriver],
                                    weekday: DateFormatter, calendar: Calendar) -> String {
        guard let today = forecast.today else { return "" }
        guard today.tendon != nil else { return "The muscle sets the forecast." }

        let tendon = group.tendonLabel ?? "tendon"
        guard today.governing == .tendon else {
            return "The \(tendon) is clear, so the muscle sets the forecast."
        }
        // Naming the day the muscle clears is what makes the tendon's slower return
        // legible — without it "takes longer" has nothing to be longer than.
        let muscleClears = Array(forecast.ahead).firstIndex { $0.muscle.isClear }
            .flatMap { index -> String? in
                guard index > 0,
                      let date = calendar.date(byAdding: .day, value: index, to: today.date)
                else { return nil }
                return "Muscle is clear by \(weekday.string(from: date)). "
            } ?? ""
        let cause = drivers.max { $0.date < $1.date }.map { " after \($0.title)" } ?? ""
        return "\(muscleClears)The \(tendon) takes longer\(cause), so it sets the forecast."
    }
}
