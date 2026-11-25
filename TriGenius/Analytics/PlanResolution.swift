import Foundation

// MARK: - Plan resolution: automatic values, set once before the session
//
// A plan (or template) may leave values to the app: an exercise step marked
// `"load": "auto"` (its weight from `StrengthProgression`) and an endurance
// target given as `target_percent` of the athlete's threshold for its
// `target_type` — pace: LT pace (swim: CSS), power: FTP, heart rate: LTHR;
// 105 % pace is 5 % faster. Until then the stored values are an estimate.
// `freezeDays` before the session the plan is frozen: its values are set from
// the history and thresholds of that day, the markers dropped, and only then is
// it pushed — never updated afterwards.

nonisolated enum PlanResolution {

    static let freezeDays = 4

    /// The last day whose plans are frozen by `now`.
    static func freezeLimit(now: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: freezeDays, to: calendar.startOfDay(for: now)) ?? now
    }

    /// Whether a plan on `date` is due to be frozen.
    static func isDue(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: date) <= freezeLimit(now: now, calendar: calendar)
    }

    /// The day a plan on `date` is frozen.
    static func freezeDate(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -freezeDays, to: calendar.startOfDay(for: date)) ?? date
    }

    /// Whether any step still leaves a value to the app.
    static func isRelative(_ steps: [[String: Any]]) -> Bool {
        steps.contains { step in
            StrengthProgression.isAuto(step) || step["target_percent"] != nil
                || isRelative(step["repeat_steps"] as? [[String: Any]] ?? [])
        }
    }

    /// The steps with every marker dropped — their values stay as set.
    static func frozen(_ steps: [[String: Any]]) -> [[String: Any]] {
        steps.map { step in
            var step = step
            step["load"] = nil
            step["target_percent"] = nil
            if let children = step["repeat_steps"] as? [[String: Any]] { step["repeat_steps"] = frozen(children) }
            return step
        }
    }

    /// The target value `percent` of the athlete's threshold stands for — pace
    /// in s/km (swim s/100 m), power in W, heart rate in bpm; nil when the
    /// threshold is unknown or the target type has none.
    static func thresholdTarget(type: String, percent: Double, family: SportFamily, thresholds: PerformanceSnapshot) -> Double? {
        let share = percent / 100
        guard share > 0 else { return nil }
        switch type {
        case "pace":
            let threshold = family == .swim ? thresholds.cssPaceSeconds : family == .run ? thresholds.lactateThrPaceSeconds : nil
            return threshold.map { ($0 / share).rounded() }
        case "power":
            let threshold = family == .bike ? thresholds.cyclingFTP : family == .run ? thresholds.runningFTP : nil
            return threshold.map { (Double($0) * share).rounded() }
        case "heart_rate":
            return thresholds.thresholdHR(for: family).map { (Double($0) * share).rounded() }
        default:
            return nil
        }
    }
}
