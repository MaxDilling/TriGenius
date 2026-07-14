import Foundation

// MARK: - Reminder Tool Handler
//
// Lets the coach configure WHEN the app sends push reminders ("Erweiterte
// Reminder", FEATURES.md). Always registered, like ProfileToolHandler /
// CalendarToolHandler — independent of the data source. Reads/writes the shared
// ReminderStore and reconciles the OS-scheduled (static) reminders after every
// change. The JSON-Schema tool dicts work for both backends automatically.
//
// Reminder kinds (exact tokens, no fuzzy matching):
//   check_in / weekly_review / custom        → static, fire at the exact time
//   todays_workout / sleep_advice            → dynamic, composed in background

@MainActor
final class ReminderToolHandler: CoachToolHandler {

    /// Day tokens accepted by `set_reminder`, mapped to Calendar weekdays (1=Sun).
    private static let weekdayTokens: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7
    ]
    private static let weekdayNames = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "get_reminders",
                description: "List the athlete's configured push reminders and the quiet-hours window.",
                parameters: ["type": "object", "properties": [:], "required": []]
            ),
            ToolDefinition(
                name: "set_reminder",
                description: """
                Create, update or delete a push reminder. Omit 'id' to create (needs 'kind' and 'time'); pass an existing \
                'id' to update it; pass 'id' plus delete:true to remove it. \
                Static kinds (check_in, weekly_review, custom) fire at the exact configured time even when the app is closed. \
                Dynamic kinds (todays_workout, sleep_advice) compose their text from current data and are delivered around \
                the configured time during a background refresh (timing is approximate). Use 'message' for the custom kind. \
                Quiet hours are managed by the athlete in Settings.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Existing reminder id to update or delete. Omit to create a new reminder."],
                        "delete": ["type": "boolean", "description": "Pass true with 'id' to remove that reminder."],
                        "kind": [
                            "type": "string",
                            "enum": ["check_in", "weekly_review", "custom", "todays_workout", "sleep_advice"],
                            "description": "What the reminder is about. Required when creating."
                        ],
                        "time": ["type": "string", "description": "Local time of day in 24h HH:MM format, e.g. '07:00'. Required when creating."],
                        "weekdays": [
                            "type": "array",
                            "items": [
                                "type": "string",
                                "enum": ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
                            ],
                            "description": "Days the reminder repeats on. Omit or leave empty for every day."
                        ],
                        "enabled": ["type": "boolean", "description": "Whether the reminder is active. Default true."],
                        "message": ["type": "string", "description": "Notification text for the 'custom' kind (ignored for other kinds)."]
                    ],
                    "required": []
                ]
            )
        ]
    }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "get_reminders": return getReminders()
        case "set_reminder": return await setReminder(arguments)
        default: return "Unknown reminder tool: \(name)"
        }
    }

    // MARK: - Handlers

    private func getReminders() -> String {
        let store = ReminderStore.shared
        let data: [String: Any] = [
            "reminders": store.rules.map(Self.ruleDict),
            "quiet_hours": Self.quietHoursDict(store)
        ]
        return "✓ \(store.rules.count) reminder(s) configured\n\(String(compactJSON: data))"
    }

    private func setReminder(_ args: [String: Any]) async -> String {
        let store = ReminderStore.shared
        let existing = (args["id"] as? String).flatMap { id in store.rules.first { $0.id == id } }

        if args["delete"] as? Bool == true {
            guard let existing else {
                return "✗ Error: pass the 'id' of an existing reminder to delete (see get_reminders)."
            }
            store.delete(id: existing.id)
            await ReminderScheduler.shared.reconcile()
            return "✓ Deleted reminder \(existing.id)"
        }

        let kindRaw = args["kind"] as? String
        if let kindRaw, ReminderKind(rawValue: kindRaw) == nil {
            return "✗ Error: 'kind' must be one of check_in, weekly_review, custom, todays_workout, sleep_advice."
        }
        guard let kind = kindRaw.flatMap(ReminderKind.init(rawValue:)) ?? existing?.kind else {
            return "✗ Error: 'kind' is required when creating a reminder."
        }

        // Time is required when creating; optional (keep current) when updating.
        var hour = existing?.hour
        var minute = existing?.minute
        if let timeStr = args["time"] as? String {
            guard let (h, m) = Self.parseTime(timeStr) else {
                return "✗ Error: 'time' must be 24h HH:MM, e.g. '07:00'."
            }
            hour = h; minute = m
        }
        guard let hour, let minute else {
            return "✗ Error: 'time' is required when creating a reminder."
        }

        // Weekdays: explicit tokens only (no fuzzy matching).
        var weekdays = existing?.weekdays ?? []
        if let tokens = args["weekdays"] as? [String] {
            var mapped: [Int] = []
            for t in tokens {
                guard let wd = Self.weekdayTokens[t.lowercased()] else {
                    return "✗ Error: '\(t)' is not a valid weekday. Use monday…sunday."
                }
                mapped.append(wd)
            }
            weekdays = Array(Set(mapped)).sorted()
        }

        if kind == .custom, (args["message"] as? String ?? existing?.message)?.isEmpty ?? true {
            return "✗ Error: the 'custom' kind needs a 'message'."
        }

        let rule = ReminderRule(
            id: existing?.id ?? UUID().uuidString,
            kind: kind,
            enabled: args["enabled"] as? Bool ?? existing?.enabled ?? true,
            hour: hour,
            minute: minute,
            weekdays: weekdays,
            message: args["message"] as? String ?? existing?.message
        )
        store.upsert(rule)

        // Static reminders fire via the OS; make sure we're authorized, then sync.
        if !kind.isDynamic { await NotificationCenterService.shared.requestAuthorization() }
        await ReminderScheduler.shared.reconcile()

        let verb = existing == nil ? "Created" : "Updated"
        return "✓ \(verb) reminder\n\(String(compactJSON: Self.ruleDict(rule)))"
    }

    // MARK: - Helpers

    /// Parse "HH:MM" → (hour, minute), validating ranges.
    private static func parseTime(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    private static func ruleDict(_ rule: ReminderRule) -> [String: Any] {
        var d: [String: Any] = [
            "id": rule.id,
            "kind": rule.kind.rawValue,
            "enabled": rule.enabled,
            "time": String(format: "%02d:%02d", rule.hour, rule.minute),
            "weekdays": rule.weekdays.isEmpty ? ["every day"] : rule.weekdays.map { weekdayNames[$0] }
        ]
        if let message = rule.message { d["message"] = message }
        return d
    }

    private static func quietHoursDict(_ store: ReminderStore) -> Any {
        guard let start = store.quietStartMinute, let end = store.quietEndMinute else { return NSNull() }
        return [
            "start": String(format: "%02d:%02d", start / 60, start % 60),
            "end": String(format: "%02d:%02d", end / 60, end % 60)
        ]
    }
}
