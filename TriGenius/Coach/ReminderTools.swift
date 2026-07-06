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
                Create or update a push reminder. Omit 'id' to create a new one; pass an existing 'id' to update it. \
                Static kinds (check_in, weekly_review, custom) fire at the exact configured time even when the app is closed. \
                Dynamic kinds (todays_workout, sleep_advice) compose their text from current data and are delivered around \
                the configured time during a background refresh (timing is approximate). Use 'message' for the custom kind.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Existing reminder id to update. Omit to create a new reminder."],
                        "kind": [
                            "type": "string",
                            "enum": ["check_in", "weekly_review", "custom", "todays_workout", "sleep_advice"],
                            "description": "What the reminder is about."
                        ],
                        "time": ["type": "string", "description": "Local time of day in 24h HH:MM format, e.g. '07:00'."],
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
                    "required": ["kind"]
                ]
            ),
            ToolDefinition(
                name: "delete_reminder",
                description: "Delete a configured reminder by its id.",
                parameters: [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "The reminder id to delete."]],
                    "required": ["id"]
                ]
            ),
            ToolDefinition(
                name: "set_quiet_hours",
                description: "Set or clear the quiet-hours window during which TriGenius suppresses notifications (proactive alerts and dynamic reminders). Pass both 'start' and 'end' as HH:MM to set, or omit both to clear.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "start": ["type": "string", "description": "Quiet-hours start, 24h HH:MM (e.g. '22:00'). Omit to clear."],
                        "end": ["type": "string", "description": "Quiet-hours end, 24h HH:MM (e.g. '07:00'). Omit to clear."]
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
        case "delete_reminder": return await deleteReminder(arguments)
        case "set_quiet_hours": return await setQuietHours(arguments)
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
        guard let kindRaw = args["kind"] as? String, let kind = ReminderKind(rawValue: kindRaw) else {
            return "✗ Error: 'kind' must be one of check_in, weekly_review, custom, todays_workout, sleep_advice."
        }

        let store = ReminderStore.shared
        let existing = (args["id"] as? String).flatMap { id in store.rules.first { $0.id == id } }

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

    private func deleteReminder(_ args: [String: Any]) async -> String {
        guard let id = args["id"] as? String else { return "✗ Error: 'id' is required." }
        guard ReminderStore.shared.rules.contains(where: { $0.id == id }) else {
            return "✗ Error: no reminder with id '\(id)'."
        }
        ReminderStore.shared.delete(id: id)
        await ReminderScheduler.shared.reconcile()
        return "✓ Deleted reminder \(id)"
    }

    private func setQuietHours(_ args: [String: Any]) async -> String {
        let store = ReminderStore.shared
        let startStr = args["start"] as? String
        let endStr = args["end"] as? String

        if startStr == nil, endStr == nil {
            store.setQuietHours(start: nil, end: nil)
            return "✓ Quiet hours cleared"
        }
        guard let startStr, let endStr,
              let start = Self.parseTime(startStr), let end = Self.parseTime(endStr) else {
            return "✗ Error: pass both 'start' and 'end' as 24h HH:MM, or omit both to clear."
        }
        store.setQuietHours(start: start.0 * 60 + start.1, end: end.0 * 60 + end.1)
        return "✓ Quiet hours set \(startStr)–\(endStr)"
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
