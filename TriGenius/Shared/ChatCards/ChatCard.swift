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

    // MARK: - Persistence
    //
    // Round-trips a card through the persisted chat session (`ChatStore`). A
    // `type` discriminator keys the case; associated values are all trivially
    // serializable. `SportFamily`/`SportShareModel.Metric` persist by rawValue
    // (exact, unlike the fuzzy `sportKey` classifier used by `parse`).

    func toDict() -> [String: Any] {
        switch self {
        case .workout(let id, let caption):
            var d: [String: Any] = ["type": "workout", "id": id]
            if let caption { d["caption"] = caption }
            return d
        case .workoutDiff(let id, let name, let caption, let changes):
            return ["type": "workout_diff", "id": id, "name": name, "caption": caption, "changes": changes]
        case .workoutDeleted(let name, let sport, let date):
            return ["type": "workout_deleted", "name": name, "sport": sport, "date": date.timeIntervalSince1970]
        case .metric(let key, let months):
            return ["type": "metric", "key": key, "months": months]
        case .ctlTrend:
            return ["type": "ctl_trend"]
        case .rampRate(let weeks):
            return ["type": "ramp_rate", "weeks": weeks]
        case .sportShare(let metric, let weeks):
            return ["type": "sport_share", "metric": metric.rawValue, "weeks": weeks]
        case .zones(let sport, let weeks):
            return ["type": "zones", "sport": sport.rawValue, "weeks": weeks]
        }
    }

    init?(from d: [String: Any]) {
        switch d["type"] as? String {
        case "workout":
            guard let id = d["id"] as? String else { return nil }
            self = .workout(id: id, caption: d["caption"] as? String)
        case "workout_diff":
            guard let id = d["id"] as? String, let name = d["name"] as? String,
                  let caption = d["caption"] as? String, let changes = d["changes"] as? [String] else { return nil }
            self = .workoutDiff(id: id, name: name, caption: caption, changes: changes)
        case "workout_deleted":
            guard let name = d["name"] as? String, let sport = d["sport"] as? String,
                  let ts = d["date"] as? TimeInterval else { return nil }
            self = .workoutDeleted(name: name, sport: sport, date: Date(timeIntervalSince1970: ts))
        case "metric":
            guard let key = d["key"] as? String, let months = Coerce.int(d["months"]) else { return nil }
            self = .metric(key: key, months: months)
        case "ctl_trend":
            self = .ctlTrend
        case "ramp_rate":
            guard let weeks = Coerce.int(d["weeks"]) else { return nil }
            self = .rampRate(weeks: weeks)
        case "sport_share":
            guard let raw = d["metric"] as? String, let metric = SportShareModel.Metric(rawValue: raw),
                  let weeks = Coerce.int(d["weeks"]) else { return nil }
            self = .sportShare(metric: metric, weeks: weeks)
        case "zones":
            guard let raw = d["sport"] as? String, let sport = SportFamily(rawValue: raw), sport != .other,
                  let weeks = Coerce.int(d["weeks"]) else { return nil }
            self = .zones(sport: sport, weeks: weeks)
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
