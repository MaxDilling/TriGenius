import Foundation

// MARK: - Chat card model
//
// A rich, tappable element embedded in a coach chat reply. Two producers feed
// it: the app itself (the plan-mutation tools emit workout cards via
// `CoachBrain.chatCardHandler` — never the LLM, so the card always reflects
// the stored state), and the coach's inline ```card tokens in streamed text
// (parsed by `MarkdownText` via `parse(tokenJSON:)`).

enum ChatCard: Equatable {
    /// A planned or completed workout, by store id. `caption` labels app-emitted
    /// cards ("Scheduled"); token references carry none.
    case workout(id: String, caption: String?)
    /// A modified or moved plan: field-level "old → new" lines from `WorkoutDiff`.
    case workoutDiff(id: String, name: String, caption: String, changes: [String])
    /// A deleted plan — the record is gone, so the card carries its display fields.
    case workoutDeleted(name: String, sport: String, date: Date)
    case metric(key: String, months: Int)
    case ctlTrend
    case rampRate(weeks: Int)
    case sportShare(metric: SportShareModel.Metric, weeks: Int)
    case zones(sport: SportFamily, weeks: Int)

    /// Parse an inline ```card token body (one single-line JSON object). Strict:
    /// anything malformed or unknown returns nil and stays visible as a code
    /// block — a coach mistake is never silently hidden.
    static func parse(tokenJSON: String) -> ChatCard? {
        guard let data = tokenJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let id = obj["workout"] as? String, !id.isEmpty {
            return .workout(id: id, caption: nil)
        }
        switch obj["chart"] as? String {
        case "metric":
            guard let key = obj["key"] as? String, PerformanceMetric.metric(for: key) != nil else { return nil }
            return .metric(key: key, months: Coerce.int(obj["months"]) ?? 3)
        case "ctl_trend":
            return .ctlTrend
        case "ramp_rate":
            return .rampRate(weeks: Coerce.int(obj["weeks"]) ?? 13)
        case "sport_share":
            let metric = (obj["metric"] as? String).flatMap(SportShareModel.Metric.init(rawValue:)) ?? .tss
            return .sportShare(metric: metric, weeks: Coerce.int(obj["weeks"]) ?? 13)
        case "zones":
            guard let sport = (obj["sport"] as? String).map(SportFamily.init(sportKey:)), sport != .other else { return nil }
            return .zones(sport: sport, weeks: Coerce.int(obj["weeks"]) ?? 4)
        default:
            return nil
        }
    }
}

/// Navigation value a tapped workout card pushes onto the chat's stack — an id,
/// not a record, so the destination resolves the live row at tap time.
enum ChatCardDestination: Hashable {
    case workout(id: String)
}
