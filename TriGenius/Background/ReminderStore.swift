import Foundation
import Combine

// MARK: - Reminder Store
//
// Single source of truth for user/coach-configurable push reminders
// ("Erweiterte Reminder", FEATURES.md). Persisted as its own JSON file in
// Application Support — deliberately NOT part of coach_memory.json, because that
// file is fully replaced on import (CoachMemory.importJSON) and the background
// task needs a `.shared` accessor (CoachMemory is a SwiftUI @StateObject).
//
// Two delivery flavors (see ReminderScheduler / BackgroundCoordinator):
//   • static kinds  → fixed-text, scheduled with the OS at the exact time.
//   • dynamic kinds → text composed from fresh data during a background refresh.

/// What a reminder is about. Raw values are the snake_case tokens used by the
/// persisted JSON and the coach tool schema (exact match — no fuzzy mapping).
enum ReminderKind: String, CaseIterable {
    case checkIn = "check_in"            // static: nudge to check in with the coach
    case weeklyReview = "weekly_review"  // static: weekly review prompt
    case custom = "custom"               // static: user/coach free text
    case todaysWorkout = "todays_workout" // dynamic: today's planned session
    case sleepAdvice = "sleep_advice"     // dynamic: morning sleep-vs-load advice

    /// Dynamic kinds compose their body at delivery time, so they ride the
    /// background-refresh path instead of an OS calendar trigger.
    var isDynamic: Bool { self == .todaysWorkout || self == .sleepAdvice }

    /// Fallback notification body for static kinds without a custom message.
    var defaultMessage: String {
        switch self {
        case .checkIn: return "Time to check in with your coach."
        case .weeklyReview: return "Let's review how your training week went."
        case .custom: return "Reminder from TriGenius."
        case .todaysWorkout: return "Here's your session for today."
        case .sleepAdvice: return "A note on today's training given your sleep."
        }
    }

    /// Deterministic chat prompt to pre-fill (unsent) when the athlete taps this
    /// reminder's notification. nil → tapping just opens the app. `.custom` is free
    /// text with no inherent intent, so it carries no prompt.
    var followUpPrompt: String? {
        switch self {
        case .checkIn: return "How am I tracking toward my goals?"
        case .weeklyReview: return "Give me a review of my training week."
        case .todaysWorkout: return "Walk me through today's workout."
        case .sleepAdvice: return "Given how I slept, how should I approach today's training?"
        case .custom: return nil
        }
    }
}

/// A single configured reminder.
struct ReminderRule: Identifiable {
    var id: String                 // stable UUID string
    var kind: ReminderKind
    var enabled: Bool
    var hour: Int                  // 0–23, local time
    var minute: Int                // 0–59
    var weekdays: [Int]            // Calendar weekday 1=Sun…7=Sat; [] = every day
    var message: String?           // required for .custom; ignored for dynamic kinds

    init(id: String = UUID().uuidString,
         kind: ReminderKind,
         enabled: Bool = true,
         hour: Int,
         minute: Int,
         weekdays: [Int] = [],
         message: String? = nil) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.message = message
    }

    init?(from d: [String: Any]) {
        guard let id = d["id"] as? String,
              let kindRaw = d["kind"] as? String,
              let kind = ReminderKind(rawValue: kindRaw) else { return nil }
        self.id = id
        self.kind = kind
        self.enabled = d["enabled"] as? Bool ?? true
        self.hour = d["hour"] as? Int ?? 8
        self.minute = d["minute"] as? Int ?? 0
        self.weekdays = (d["weekdays"] as? [Int]) ?? []
        self.message = d["message"] as? String
    }

    func toDict() -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "kind": kind.rawValue,
            "enabled": enabled,
            "hour": hour,
            "minute": minute,
            "weekdays": weekdays
        ]
        if let message { d["message"] = message }
        return d
    }

    /// Effective body for a static reminder.
    var body: String {
        if let message, !message.isEmpty { return message }
        return kind.defaultMessage
    }
}

@MainActor
final class ReminderStore: ObservableObject {
    static let shared = ReminderStore()

    @Published private(set) var rules: [ReminderRule]
    /// Quiet-hours window in minutes since local midnight; nil = no quiet hours.
    @Published private(set) var quietStartMinute: Int?
    @Published private(set) var quietEndMinute: Int?

    private let storageURL: URL

    // MARK: - Init / persistence

    init(filename: String = "reminders.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent(filename)

        rules = []
        quietStartMinute = nil
        quietEndMinute = nil
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let arr = raw["rules"] as? [[String: Any]] {
            rules = arr.compactMap(ReminderRule.init(from:))
        }
        quietStartMinute = raw["quiet_start_minute"] as? Int
        quietEndMinute = raw["quiet_end_minute"] as? Int
    }

    private func save() {
        var dict: [String: Any] = ["rules": rules.map { $0.toDict() }]
        if let quietStartMinute { dict["quiet_start_minute"] = quietStartMinute }
        if let quietEndMinute { dict["quiet_end_minute"] = quietEndMinute }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) else { return }
        let url = storageURL
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Mutation

    /// Insert a new rule or replace the existing one with the same id.
    func upsert(_ rule: ReminderRule) {
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx] = rule
        } else {
            rules.append(rule)
        }
        save()
    }

    func delete(id: String) {
        rules.removeAll { $0.id == id }
        save()
    }

    /// Set or clear the quiet-hours window (minutes since midnight, nil to clear).
    func setQuietHours(start: Int?, end: Int?) {
        quietStartMinute = start
        quietEndMinute = end
        save()
    }

    // MARK: - Queries

    /// True when `date`'s local time falls inside the quiet-hours window.
    /// Handles windows that wrap past midnight (e.g. 22:00 → 07:00).
    func isWithinQuietHours(_ date: Date = Date()) -> Bool {
        guard let start = quietStartMinute, let end = quietEndMinute, start != end else { return false }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        let now = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if start < end {
            return now >= start && now < end
        } else {
            // Wraps midnight.
            return now >= start || now < end
        }
    }

    /// Dynamic reminders that are due to fire now: enabled, dynamic kind, today's
    /// weekday matches (or every-day), the configured time has already passed
    /// today, and we're not inside quiet hours. Per-day dedup is the scheduler's
    /// job (`ReminderScheduler.dynamicDeliveredToday`).
    func dueDynamicRules(now: Date = Date()) -> [ReminderRule] {
        guard !isWithinQuietHours(now) else { return [] }
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute, .weekday], from: now)
        let weekday = comps.weekday ?? 1
        let minutesNow = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return rules.filter { rule in
            guard rule.enabled, rule.kind.isDynamic else { return false }
            guard rule.weekdays.isEmpty || rule.weekdays.contains(weekday) else { return false }
            return rule.hour * 60 + rule.minute <= minutesNow
        }
    }
}
