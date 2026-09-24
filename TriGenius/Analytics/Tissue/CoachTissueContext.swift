import Foundation

// MARK: - Coach hand-off payload
//
// What the coach is told when the athlete asks about a group. Numbers, not prose: the
// forecast, what caused it, what is coming that loads the group again, and how much of
// it is guesswork. The coach explains and offers options; it never re-derives any of
// this itself.
//
// Keys are snake_case like every other payload the coach sees, and dates are plain
// calendar days — the model has no use for a timestamp's precision.

nonisolated struct CoachTissueContext: Encodable, Sendable {
    enum Confidence: String, Encodable, Sendable { case moderate, high }

    struct Driver: Encodable, Sendable {
        let date: String
        let sport: String
        let title: String
    }

    struct Planned: Encodable, Sendable {
        let date: String
        let title: String
        let isKey: Bool
        let morningLevel: Int
        let conflict: Bool

        enum CodingKeys: String, CodingKey {
            case date, title
            case isKey = "is_key"
            case morningLevel = "morning_level"
            case conflict
        }
    }

    let source = "dashboard.tissue_load"
    let group: String
    let governingTissue: String
    /// "Achilles" — nil when the group has no named tendon.
    let governingTissueLabel: String?
    let clearOn: String?
    let confidence: Confidence
    let muscleLevels: [Int]
    let tendonLevels: [Int]?
    let drivers: [Driver]
    let plannedAffecting: [Planned]
    /// Groups whose load is partly unlogged, so their state is a range, not a number.
    /// "over target, 5 of 6 wk" — nil until six weeks of history exist.
    let chronicSummary: String?
    let intent = "explain_then_offer_options"

    enum CodingKeys: String, CodingKey {
        case source, group, confidence, drivers, intent
        case governingTissue = "governing_tissue"
        case governingTissueLabel = "governing_tissue_label"
        case clearOn = "clear_on"
        case muscleLevels = "muscle_levels"
        case tendonLevels = "tendon_levels"
        case plannedAffecting = "planned_affecting"
        case chronicSummary = "chronic_summary"
    }

    /// Nil when the group isn't modelled in this forecast set.
    static func make(group: TissueGroup, input: TissueCardModel.Input,
                     chronicSummary: String? = nil,
                     calendar: Calendar = .current) -> CoachTissueContext? {
        guard let forecast = input.forecasts.first(where: { $0.group == group }),
              let today = forecast.today else { return nil }

        let days = DateFormatter()
        days.locale = Locale(identifier: "en_US_POSIX")
        days.calendar = calendar
        days.timeZone = calendar.timeZone
        days.dateFormat = "yyyy-MM-dd"

        let ahead = Array(forecast.ahead)
        let clearOn = TissueLogic.clearDay(forecast).flatMap {
            calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: input.today))
        }

        let conflicting = Set(input.conflicts.filter { $0.group == group }.map(\.session.id))
        let affecting = input.planned
            .filter { $0.loads.contains(group) && $0.date >= input.today }
            .sorted { $0.date < $1.date }

        return CoachTissueContext(
            group: group.rawValue,
            governingTissue: today.governing.rawValue,
            governingTissueLabel: today.governing == .tendon ? group.tendonLabel : nil,
            clearOn: clearOn.map(days.string(from:)),
            // Coarse on purpose: how much to trust the forecast, not a percentage the
            // model would over-read.
            confidence: input.sessionCount >= TissueConstants.minimumSessionsForAdvice ? .high : .moderate,
            muscleLevels: ahead.map(\.muscle.rawValue),
            tendonLevels: ahead.contains { $0.tendon != nil }
                ? ahead.map { ($0.tendon ?? $0.muscle).rawValue } : nil,
            drivers: input.drivers
                .filter { $0.loads.contains(group) }
                .sorted { $0.date > $1.date }
                .map { Driver(date: days.string(from: $0.date), sport: $0.sport.rawValue, title: $0.title) },
            plannedAffecting: affecting.map { session in
                let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: input.today),
                                                     to: calendar.startOfDay(for: session.date)).day ?? 0
                let morning = ahead.indices.contains(offset) ? ahead[offset].governingLevel : today.governingLevel
                return Planned(date: days.string(from: session.date), title: session.title,
                               isKey: session.isKey, morningLevel: morning.rawValue,
                               conflict: conflicting.contains(session.id))
            },
            chronicSummary: chronicSummary)
    }
}
