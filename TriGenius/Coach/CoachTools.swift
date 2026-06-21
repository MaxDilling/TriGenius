import Foundation

// MARK: - Tool Execution Protocol
// All tool handlers run on the MainActor to allow safe access to CoachMemory.

@MainActor
protocol CoachToolHandler {
    var definitions: [ToolDefinition] { get }
    func execute(name: String, arguments: [String: Any]) async throws -> String
}

// MARK: - Tool Registry

@MainActor
final class CoachToolRegistry {
    private var handlers: [String: any CoachToolHandler] = [:]
    private(set) var allDefinitions: [ToolDefinition] = []

    func register(_ handler: some CoachToolHandler) {
        for def in handler.definitions {
            handlers[def.name] = handler
        }
        allDefinitions.append(contentsOf: handler.definitions)
    }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        guard let handler = handlers[name] else {
            return "Error: Unknown tool '\(name)'"
        }
        return try await handler.execute(name: name, arguments: arguments)
    }
}

// MARK: - HealthKit Tool Handler

@MainActor
final class HealthKitToolHandler: CoachToolHandler {
    private let healthKit = HealthKitService.shared

    var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "get_health_metrics",
                description: "Fetch health metrics from Apple Health for the last N days. Returns steps, resting heart rate, HRV, sleep duration, and active energy.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "days": [
                            "type": "integer",
                            "description": "Number of past days to include (1–30). Default 7."
                        ]
                    ],
                    "required": []
                ]
            ),
            ToolDefinition(
                name: "get_activities",
                description: "Fetch recent workouts from Apple Health. Returns type, date, duration, distance, and energy for each activity.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "count": [
                            "type": "integer",
                            "description": "Number of recent workouts to return (1–30). Default 10."
                        ]
                    ],
                    "required": []
                ]
            )
        ]
    }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "get_health_metrics":
            let days = arguments["days"] as? Int ?? 7
            return try await fetchHealthMetrics(days: days)
        case "get_activities":
            // Served from the local database (synced on launch), not live HealthKit.
            let count = arguments["count"] as? Int ?? 10
            return await DataSyncCoordinator.shared.activities(
                source: .appleHealth, sport: nil, count: count, days: nil
            )
        default:
            return "Unknown health tool: \(name)"
        }
    }

    private func fetchHealthMetrics(days: Int) async throws -> String {
        do {
            try await healthKit.requestAuthorization()
            let metrics = try await healthKit.fetchHealthMetrics(days: days)
            return metrics.toJSONString()
        } catch {
            return "HealthKit error: \(error.localizedDescription). Make sure health permissions are granted."
        }
    }

}

// MARK: - Profile Tool Handler

@MainActor
final class ProfileToolHandler: CoachToolHandler {
    private let memory: CoachMemory

    init(memory: CoachMemory) {
        self.memory = memory
    }

    var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "update_athlete_profile",
                description: "Persist athlete profile changes, preferences, goals, sport limitations, and training-plan metadata in long-term memory.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Athlete name."],
                        "add_goal": ["type": "string", "description": "Goal to add."],
                        "remove_goal": ["type": "string", "description": "Goal to remove."],
                        "max_weekly_hours": ["type": "integer", "description": "Maximum training hours per week."],
                        "max_hr": ["type": "integer", "description": "Maximum heart rate in bpm."],
                        "preferred_rest_day": ["type": "string", "description": "Preferred rest day."],
                        "morning_workouts": ["type": "boolean", "description": "Whether morning workouts are preferred."],
                        "indoor_trainer_available": ["type": "boolean", "description": "Whether an indoor trainer is available."],
                        "target_event": ["type": "string", "description": "Primary target race or event."],
                        "event_date": ["type": "string", "description": "Event date in YYYY-MM-DD format."],
                        "current_phase": ["type": "string", "description": "Current training phase (base/build/peak/taper/recovery)."],
                        "monthly_focus": ["type": "string", "description": "Main focus for the current month."],
                        "feedback": ["type": "string", "description": "Athlete feedback to record."],
                        "feedback_category": ["type": "string", "description": "Feedback category: schedule, intensity, recovery, injury, or progress."],
                        "sport": [
                            "type": "string",
                            "enum": ["swimming", "cycling", "running", "strength"],
                            "description": "Sport to update for sport-specific fields."
                        ],
                        "add_sport_ability": ["type": "string", "description": "Ability the athlete has for the selected sport."],
                        "add_sport_limitation": ["type": "string", "description": "Limitation to persist for the selected sport."],
                        "sport_limitation_reason": ["type": "string", "description": "Optional reason for the limitation."],
                        "set_sport_level": ["type": "string", "description": "Sport level: beginner, intermediate, or advanced."],
                        "set_sport_focus": ["type": "string", "description": "Current training focus for the sport."],
                        "add_sport_equipment": ["type": "string", "description": "Equipment available for the sport."],
                        "add_sport_injury": ["type": "string", "description": "Injury affecting the sport."],
                        "add_sport_injury_impact": ["type": "string", "description": "Impact of the injury on training."]
                    ],
                    "required": []
                ]
            ),
            ToolDefinition(
                name: "get_athlete_profile",
                description: "Retrieve the current athlete profile, preferences, training plan and sport-specific progress from memory.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ),
            ToolDefinition(
                name: "read_knowledge",
                description: "Read coaching knowledge files on specific topics: cycling, running, swimming, or injuries. Always call this FIRST when answering sport-specific training questions.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "topic": [
                            "type": "string",
                            "enum": ["cycling", "running", "swimming", "injuries"],
                            "description": "The topic to read."
                        ]
                    ],
                    "required": ["topic"]
                ]
            )
        ]
    }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "update_athlete_profile":
            return updateProfile(arguments: arguments)
        case "get_athlete_profile":
            return memory.contextSummary(performance: TrainingDataStore.shared.latestSnapshot())
        case "read_knowledge":
            let topic = arguments["topic"] as? String ?? ""
            return knowledgeSummary(for: topic)
        default:
            return "Unknown profile tool: \(name)"
        }
    }

    private func updateProfile(arguments: [String: Any]) -> String {
        var updates: [String] = []

        if let name = arguments["name"] as? String {
            memory.updateProfile { $0.name = name }
            updates.append("name → \(name)")
        }
        if let goal = arguments["add_goal"] as? String {
            memory.updateProfile { p in
                if !p.goals.contains(goal) { p.goals.append(goal) }
            }
            updates.append("added goal: \(goal)")
        }
        if let goal = arguments["remove_goal"] as? String {
            memory.updateProfile { p in p.goals.removeAll { $0 == goal } }
            updates.append("removed goal: \(goal)")
        }
        if let hours = arguments["max_weekly_hours"] as? Int {
            memory.updateWeeklyStructure { $0.maxHours = hours }
            updates.append("max weekly hours → \(hours)")
        }
        if let maxHR = arguments["max_hr"] as? Int {
            // Max HR is a performance value: store it in the DB time series
            // alongside FTP/CSS/etc., not in the profile JSON.
            TrainingDataStore.shared.ingestMetrics([
                IngestedMetric(metricKey: "max_hr", value: Double(maxHR), unit: "bpm", source: "manual", date: Date())
            ])
            updates.append("max HR → \(maxHR)")
        }
        if let day = arguments["preferred_rest_day"] as? String {
            memory.updateWeeklyStructure { $0.preferredRestDay = day }
            updates.append("rest day → \(day)")
        }
        if let morning = arguments["morning_workouts"] as? Bool {
            memory.updatePreferences { $0.morningWorkouts = morning }
            updates.append("morning workouts → \(morning)")
        }
        if let trainer = arguments["indoor_trainer_available"] as? Bool {
            memory.updatePreferences { $0.indoorTrainerAvailable = trainer }
            updates.append("indoor trainer → \(trainer)")
        }
        if let ev = arguments["target_event"] as? String {
            memory.updateTrainingPlan { $0.targetEvent = ev }
            updates.append("target event → \(ev)")
        }
        if let dt = arguments["event_date"] as? String {
            memory.updateTrainingPlan { $0.eventDate = dt }
            updates.append("event date → \(dt)")
        }
        if let phase = arguments["current_phase"] as? String {
            memory.updateTrainingPlan { $0.currentPhase = phase }
            updates.append("phase → \(phase)")
        }
        if let focus = arguments["monthly_focus"] as? String {
            memory.updateTrainingPlan { $0.monthlyFocus = focus }
            updates.append("monthly focus → \(focus)")
        }
        if let fb = arguments["feedback"] as? String {
            let cat = arguments["feedback_category"] as? String ?? "general"
            memory.addFeedback(fb, category: cat)
            updates.append("feedback recorded")
        }

        // Sport-specific updates
        if let sport = arguments["sport"] as? String {
            if let ability = arguments["add_sport_ability"] as? String {
                memory.updateSportProgress(sport: sport) { sp in
                    if !sp.abilities.contains(ability) { sp.abilities.append(ability) }
                }
                updates.append("[\(sport)] ability: \(ability)")
            }
            if let lim = arguments["add_sport_limitation"] as? String {
                let reason = arguments["sport_limitation_reason"] as? String
                memory.updateSportProgress(sport: sport) { sp in
                    var d: [String: Any] = ["item": lim]
                    if let r = reason { d["reason"] = r }
                    if let limitation = Limitation(from: d) {
                        sp.limitations.append(limitation)
                    }
                }
                updates.append("[\(sport)] limitation: \(lim)")
            }
            if let lvl = arguments["set_sport_level"] as? String {
                memory.updateSportProgress(sport: sport) { $0.currentLevel = lvl }
                updates.append("[\(sport)] level: \(lvl)")
            }
            if let sfocus = arguments["set_sport_focus"] as? String {
                memory.updateSportProgress(sport: sport) { $0.currentFocus = sfocus }
                updates.append("[\(sport)] focus: \(sfocus)")
            }
            if let eq = arguments["add_sport_equipment"] as? String {
                memory.updateSportProgress(sport: sport) { sp in
                    if !sp.equipment.contains(eq) { sp.equipment.append(eq) }
                }
                updates.append("[\(sport)] equipment: \(eq)")
            }
            if let injury = arguments["add_sport_injury"] as? String,
               let impact = arguments["add_sport_injury_impact"] as? String {
                memory.updateSportProgress(sport: sport) { sp in
                    sp.injuriesAffecting.append(InjuryImpact(from: ["injury": injury, "impact": impact])!)
                }
                updates.append("[\(sport)] injury impact: \(injury)")
            }
        }

        if updates.isEmpty {
            return "No updates provided."
        }
        return "Profile updated: \(updates.joined(separator: ", "))"
    }

    /// Maps a topic to its knowledge file (in `Assets/Knowledge/`) and the
    /// embedded fallback used when the bundled file can't be loaded.
    private static let knowledgeFiles: [String: (resource: String, ext: String, fallback: String)] = [
        "cycling":  ("CYCLING",  "md", CoachKnowledge.cycling),
        "running":  ("RUNNING",  "md", CoachKnowledge.running),
        "swimming": ("SWIMMING", "md", CoachKnowledge.swimming),
        "injuries": ("INJURIES", "MD", CoachKnowledge.injuries)
    ]

    private func knowledgeSummary(for topic: String) -> String {
        guard let entry = Self.knowledgeFiles[topic] else {
            let available = Self.knowledgeFiles.keys.sorted().joined(separator: ", ")
            return "Unknown topic: \(topic). Available: \(available)."
        }

        // Synchronized groups copy the .md files into the bundle's resource
        // root (flattened), so look them up by name without a subdirectory.
        if let url = Bundle.main.url(forResource: entry.resource, withExtension: entry.ext),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            return contents
        }

        // Fall back to the embedded constant if the file is missing.
        return entry.fallback
    }
}

// MARK: - Calendar Tool Handler
//
// Always registered (like ProfileToolHandler), independent of the active data
// source. Exposes the athlete's real-world schedule so the coach can plan
// workouts around busy days. As a JSON-Schema tool it works for both backends
// automatically — no backend-specific code.

@MainActor
final class CalendarToolHandler: CoachToolHandler {
    private let calendar = CalendarService.shared

    var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "read_calendar_availability",
                description: "Read the athlete's real-world schedule (busy/free windows) from their device calendar for a date range, so workouts can be planned around busy days. Returns per-day busy minutes and the events on each day. Use this before proposing or rescheduling sessions on specific days.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "start_date": ["type": "string", "description": "Start date in YYYY-MM-DD format. Defaults to today."],
                        "end_date": ["type": "string", "description": "End date in YYYY-MM-DD format. Defaults to 7 days after the start."]
                    ],
                    "required": []
                ]
            )
        ]
    }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        guard name == "read_calendar_availability" else {
            return "Unknown calendar tool: \(name)"
        }

        let granted = await calendar.requestAccess()
        guard granted else {
            return "Calendar access is not granted. Ask the athlete to enable 'Calendar' for TriGenius in Settings to plan around their schedule."
        }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = (arguments["start_date"] as? String).flatMap(DataSyncCoordinator.ymd.date(from:)) ?? today
        let defaultEnd = cal.date(byAdding: .day, value: 7, to: start) ?? start
        let end = (arguments["end_date"] as? String).flatMap(DataSyncCoordinator.ymd.date(from:)) ?? defaultEnd

        let days = calendar.availability(from: start, to: max(start, end))
        let payload: [[String: Any]] = days.map { day in
            [
                "date": DataSyncCoordinator.ymd.string(from: day.date),
                "busy_minutes": day.busyMinutes,
                "all_day_event": day.allDay,
                "events": day.windows.map { w -> [String: Any] in
                    [
                        "title": w.title,
                        "all_day": w.isAllDay,
                        "start": Self.timeFormatter.string(from: w.start),
                        "end": Self.timeFormatter.string(from: w.end),
                        "duration_minutes": w.durationMinutes
                    ]
                }
            ]
        }
        let data: [String: Any] = [
            "days": payload,
            "count": payload.count,
            "range": ["start": DataSyncCoordinator.ymd.string(from: start), "end": DataSyncCoordinator.ymd.string(from: max(start, end))]
        ]
        let json = (try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "✓ Calendar availability for \(payload.count) day(s)\n\(json)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

// MARK: - Garmin Tool Handler
//
// Exposes the same 8 Garmin tools as the Python CLI. Tool names mirror the
// HealthKit handler (get_activities / get_health_metrics) so the coach is
// agnostic to the active data source.

@MainActor
final class GarminToolHandler: CoachToolHandler {
    private let memory: CoachMemory
    private let service = GarminService.shared

    init(memory: CoachMemory) {
        self.memory = memory
    }

    var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "get_health_metrics",
                description: "Fetch recovery data from Garmin: HRV, sleep, and short-term trends.",
                parameters: [
                    "type": "object",
                    "properties": ["days": ["type": "integer", "description": "Number of days to fetch. Default 7."]],
                    "required": []
                ]
            ),
            ToolDefinition(
                name: "get_activities",
                description: "Fetch recent completed Garmin activities with sport-specific metrics for analysis.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "sport": ["type": "string", "enum": ["running", "cycling", "swimming", "strength", "gym", "hiking", "walking"], "description": "Optional sport filter."],
                        "count": ["type": "integer", "description": "Maximum number of activities to return. Default 10."],
                        "days": ["type": "integer", "description": "Only include activities from the last N days."]
                    ],
                    "required": []
                ]
            ),
            ToolDefinition(
                name: "get_power_curve",
                description: "Compute a cycling power-duration curve from Garmin activity details over a date range.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "start_date": ["type": "string", "description": "Start date in YYYY-MM-DD format."],
                        "end_date": ["type": "string", "description": "End date in YYYY-MM-DD format."],
                        "sport": ["type": "string", "enum": ["cycling"], "description": "Currently only cycling is supported."],
                        "durations_seconds": ["type": "array", "description": "Optional custom duration list in seconds.", "items": ["type": "integer"]]
                    ],
                    "required": ["start_date", "end_date"]
                ]
            ),
            ToolDefinition(
                name: "get_calendar",
                description: "Fetch Garmin calendar workouts and completed activities for a date range.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "start_date": ["type": "string", "description": "Start date in YYYY-MM-DD format."],
                        "end_date": ["type": "string", "description": "End date in YYYY-MM-DD format."]
                    ],
                    "required": ["start_date", "end_date"]
                ]
            ),
            ToolDefinition(
                name: "delete_workout",
                description: "Delete a scheduled Garmin workout by ID.",
                parameters: [
                    "type": "object",
                    "properties": ["workout_id": ["type": "string", "description": "Workout ID from get_calendar."]],
                    "required": ["workout_id"]
                ]
            ),
            ToolDefinition(
                name: "add_workout",
                description: "Create and schedule a structured Garmin workout for running, cycling, swimming, or strength.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "workout_data": [
                            "type": "object",
                            "description": "Workout definition object.",
                            "properties": [
                                "name": ["type": "string", "description": "Workout name."],
                                "sport": ["type": "string", "enum": ["running", "cycling", "swimming", "strength", "yoga", "cardio", "other"], "description": "Workout sport."],
                                "duration_minutes": ["type": "integer", "description": "Total duration in minutes."],
                                "distance_meters": ["type": "number", "description": "Optional total distance in meters."],
                                "pool_length": ["type": "integer", "description": "Pool length in meters for swim workouts."],
                                "description": ["type": "string", "description": "Workout description."],
                                "include_warmup": ["type": "boolean", "description": "Include a warm-up block."],
                                "include_cooldown": ["type": "boolean", "description": "Include a cool-down block."],
                                "steps": [
                                    "type": "array",
                                    "description": "Optional structured workout steps.",
                                    "items": [
                                        "type": "object",
                                        "properties": [
                                            "type": ["type": "string", "enum": ["warmup", "interval", "main", "recovery", "rest", "cooldown", "repeat"], "description": "Step type."],
                                            "duration_seconds": ["type": "integer", "description": "Step duration in seconds."],
                                            "distance_meters": ["type": "number", "description": "Step distance in meters."],
                                            "end_condition": ["type": "string", "enum": ["time", "distance", "lap_button", "fixed_rest"], "description": "How the step ends."],
                                            "stroke": ["type": "string", "enum": ["free", "breaststroke", "backstroke", "butterfly", "any_stroke", "drill", "im"], "description": "Swim stroke for swimming steps."],
                                            "repeat_count": ["type": "integer", "description": "Iterations for repeat blocks."],
                                            "repeat_steps": [
                                                "type": "array",
                                                "description": "Child steps inside a repeat block.",
                                                "items": [
                                                    "type": "object",
                                                    "properties": [
                                                        "type": ["type": "string", "description": "Child step type."],
                                                        "distance_meters": ["type": "number", "description": "Child step distance in meters."],
                                                        "duration_seconds": ["type": "integer", "description": "Child step duration in seconds."],
                                                        "stroke": ["type": "string", "description": "Child step swim stroke."]
                                                    ]
                                                ]
                                            ],
                                            "skip_last_rest": ["type": "boolean", "description": "Skip the last rest in a repeat block."],
                                            "target_type": ["type": "string", "enum": ["no_target", "heart_rate", "power", "pace", "cadence"], "description": "Garmin target type."],
                                            "target_low": ["type": "number", "description": "Lower target bound."],
                                            "target_high": ["type": "number", "description": "Upper target bound."]
                                        ]
                                    ]
                                ]
                            ],
                            "required": ["name", "sport", "duration_minutes"]
                        ],
                        "date": ["type": "string", "description": "Target date in YYYY-MM-DD format."]
                    ],
                    "required": ["workout_data", "date"]
                ]
            ),
            ToolDefinition(
                name: "move_workout",
                description: "Move a scheduled Garmin workout from one date to another.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "from_date": ["type": "string", "description": "Current workout date in YYYY-MM-DD format."],
                        "to_date": ["type": "string", "description": "Target workout date in YYYY-MM-DD format."],
                        "workout_id": ["type": "string", "description": "Optional specific workout ID."]
                    ],
                    "required": ["from_date", "to_date"]
                ]
            ),
            ToolDefinition(
                name: "get_training_status",
                description: "Fetch Garmin training status for a specific date, including Chronic Load, Acute Load, and the distribution of Anaerobic, High Aerobic, and Low Aerobic training load balance.",
                parameters: [
                    "type": "object",
                    "properties": ["target_date": ["type": "string", "description": "Target date in YYYY-MM-DD format."]],
                    "required": ["target_date"]
                ]
            ),
            ToolDefinition(
                name: "sync_user_settings",
                description: "Sync Garmin-derived athlete settings such as FTP, HR zones, VO2max, weight, and CSS.",
                parameters: ["type": "object", "properties": [:], "required": []]
            )
        ]
    }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        // Activities are served from the local database (synced on launch), so
        // this works even when Garmin is offline / not currently connected.
        if name == "get_activities" {
            return await DataSyncCoordinator.shared.activities(
                source: .garmin,
                sport: arguments["sport"] as? String,
                count: intArg(arguments["count"]) ?? 10,
                days: intArg(arguments["days"])
            )
        }

        let connected = await GarminAuth.shared.isAuthenticated
        guard connected else {
            return "Garmin is not connected. Please sign in under 'Garmin Connect' in Settings."
        }

        switch name {
        case "get_health_metrics":
            return await service.getHealthMetrics(days: intArg(arguments["days"]) ?? 7)
        case "get_power_curve":
            let durations = (arguments["durations_seconds"] as? [Any])?.compactMap { intArg($0) }
            return await service.getPowerCurve(
                startDate: arguments["start_date"] as? String ?? "",
                endDate: arguments["end_date"] as? String ?? "",
                sport: arguments["sport"] as? String ?? "cycling",
                durationsSeconds: durations
            )
        case "get_calendar":
            return await service.getCalendar(
                startDate: arguments["start_date"] as? String ?? "",
                endDate: arguments["end_date"] as? String ?? ""
            )
        case "delete_workout":
            let workoutId = stringArg(arguments["workout_id"]) ?? ""
            let result = await service.deleteWorkout(workoutId: workoutId)
            if result.hasPrefix("✓") {
                TrainingDataStore.shared.deleteScheduledWorkout(id: "garmin:\(workoutId)")
            }
            return result
        case "add_workout":
            guard let workoutData = arguments["workout_data"] as? [String: Any] else {
                return "✗ Error: workout_data is missing or invalid."
            }
            let result = await service.addWorkout(workoutData: workoutData, date: arguments["date"] as? String ?? "")
            ingestAddedWorkout(result, workoutData: workoutData)
            return result
        case "move_workout":
            let result = await service.moveWorkout(
                fromDate: arguments["from_date"] as? String ?? "",
                toDate: arguments["to_date"] as? String ?? "",
                workoutId: stringArg(arguments["workout_id"])
            )
            applyMovedWorkout(result)
            return result
        case "get_training_status":
            return await service.getTrainingStatus(targetDate: arguments["target_date"] as? String ?? "")
        case "sync_user_settings":
            let (text, settings) = await service.syncUserSettings()
            if let settings { applySettingsToMemory(settings) }
            return text
        default:
            return "Unknown Garmin tool: \(name)"
        }
    }

    // MARK: - Argument coercion

    private func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private func stringArg(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return "\(n)" }
        return nil
    }

    // MARK: - Local scheduled-workout mirror
    //
    // Keep the local scheduled-workout store in step with the coach's Garmin
    // scheduling actions so the dashboard/calendar update immediately, without
    // waiting for the next full calendar sync.

    /// The JSON payload embedded in a "✓ message\n<json>" tool result.
    private func resultData(_ result: String) -> [String: Any]? {
        guard result.hasPrefix("✓"), let brace = result.firstIndex(of: "{") else { return nil }
        guard let data = String(result[brace...]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Ingest a just-created Garmin workout locally (needs the id Garmin assigned).
    private func ingestAddedWorkout(_ result: String, workoutData: [String: Any]) {
        guard let data = resultData(result),
              let workoutId = data["workout_id"], !(workoutId is NSNull),
              let dateStr = data["date"] as? String,
              let date = DataSyncCoordinator.ymd.date(from: dateStr) else { return }
        let minutes = (workoutData["duration_minutes"] as? NSNumber)?.doubleValue ?? 0
        TrainingDataStore.shared.ingestScheduled([
            IngestedScheduledWorkout(
                id: "garmin:\(workoutId)",
                source: "garmin",
                date: date,
                sport: data["sport"] as? String ?? "other",
                name: data["name"] as? String ?? workoutData["name"] as? String ?? "Scheduled Workout",
                targetDurationMinutes: minutes,
                targetTSS: nil,
                notes: workoutData["description"] as? String ?? ""
            )
        ])
    }

    /// Reflect a Garmin move locally by shifting the record to its new date.
    private func applyMovedWorkout(_ result: String) {
        guard let data = resultData(result),
              let workoutId = data["workout_id"], !(workoutId is NSNull),
              let toStr = data["to_date"] as? String,
              let date = DataSyncCoordinator.ymd.date(from: toStr) else { return }
        TrainingDataStore.shared.moveScheduledWorkout(id: "garmin:\(workoutId)", to: date)
    }

    // MARK: - Persist synced settings

    private func applySettingsToMemory(_ settings: [String: Any]) {
        // All performance/biometric values (FTP, CSS, LTHR, max HR, VO2max,
        // weight, HR/power zones) go into the DB time series.
        TrainingDataStore.shared.ingestMetrics(
            DataSyncCoordinator.metrics(fromGarminSettings: settings, date: Date())
        )
    }
}

// MARK: - Embedded Knowledge Base

private enum CoachKnowledge {
    static let cycling = """
    === CYCLING COACHING KNOWLEDGE ===

    TRAINING ZONES (Power-based, % of FTP):
    Z1 Recovery: <55% FTP
    Z2 Endurance: 56–75% FTP  ← Core of base training
    Z3 Tempo: 76–90% FTP
    Z4 Threshold: 91–105% FTP
    Z5 VO2max: 106–120% FTP
    Z6 Anaerobic: >120% FTP

    BASE TRAINING PRINCIPLES:
    - 80% of volume in Z1-Z2 (aerobic base)
    - FTP gains come primarily from sustained Z2 + Z4 blocks
    - Polarized: ~80% easy, ~20% hard — well-evidenced for trained athletes
    - Pyramidal: ~75% easy, ~15% moderate, ~10% hard — valid alternative

    STAGNATION CHECKLIST (in order):
    1. Consistency: gaps >1 week in past 3 months?
    2. Volume: total weekly TSS, not just intensity
    3. Frequency: 3+ rides/week needed for meaningful adaptation
    4. Specificity: are you training the demands of your goal event?
    5. Recovery: sleep, nutrition, non-training stress
    6. Intensity distribution: only after 1–5 are adequate

    COMMON MISTAKES:
    - Everything in "no man's land" (Z3) — neither easy enough for recovery nor hard enough for adaptation
    - FTP testing too frequently (every 4–6 weeks is sufficient)
    - Neglecting long Z2 rides (2+ hours) for aerobic adaptation
    - Indoor vs outdoor calibration: power meters may read differently; recalibrate if switching

    DEVICE DATA CAVEATS:
    - FTP estimates from devices: treat as ±5–10% approximation
    - Power meters need regular calibration (temperature affects readings)
    - HR lags 30–90s behind power during intervals — use power + RPE for pacing
    """

    static let running = """
    === RUNNING COACHING KNOWLEDGE ===

    TRAINING ZONES (HR or pace-based):
    Z1 Easy: conversational pace, <70% HRmax
    Z2 Aerobic: 70–80% HRmax, can speak in short sentences
    Z3 Tempo: 80–87% HRmax, controlled discomfort
    Z4 Threshold: 87–93% HRmax
    Z5 VO2max: >93% HRmax, 3–8 min intervals

    VOLUME PROGRESSION:
    - 10% rule (max weekly increase): evidence is weak, but cautious progression is sound
    - Practical guideline: increase every 3 weeks, recover on week 4
    - New runners: build base for 8–12 weeks before adding intensity
    - Base mileage matters more than workout complexity

    INJURY PREVENTION:
    - Shin splints: reduce volume, check shoes, surface variety
    - Knee pain: check cadence (aim 170–180 spm), hip strength
    - Achilles/calf: eccentric heel drops; never ignore persistent pain
    - Most running injuries: too much, too soon, too fast

    RACE PREP:
    - 5K/10K: VO2max intervals (3–5 min @ Z5) + threshold
    - Half marathon: threshold + long run
    - Marathon: 80% Z1-Z2, long runs 90–180 min, periodic tempo
    - Triathlon run: practice brick sessions (bike → run)

    COMMON MISTAKES:
    - Running every day without rest → accumulation injury
    - All runs at the same moderate effort
    - Ignoring cadence and form under fatigue
    - Tapering too aggressively (2 weeks for half, 3 weeks for marathon)
    """

    static let swimming = """
    === SWIMMING COACHING KNOWLEDGE ===

    KEY METRICS:
    - CSS (Critical Swim Speed): lactate threshold pace, key for aerobic training
    - T-pace: CSS equivalent, basis for interval pacing
    - Stroke efficiency: distance per stroke (DPS) + stroke rate

    TECHNIQUE PRIORITY (beginners):
    - Body position / balance first — most efficiency gains come from this
    - Bilateral breathing (every 3 strokes) for symmetrical development
    - High elbow catch — avoid crossing over the centerline
    - Don't kick hard for propulsion; kick for balance and body position

    DRILLS:
    - Catch-up drill: timing and reach
    - Fingertip drag: high elbow recovery
    - Kick on side: balance and rotation
    - Pull buoy: isolate upper body, feel body position

    TRAINING STRUCTURE:
    - Warm-up: 10–15% of total volume
    - CSS intervals: 200–400m reps at T-pace, 15–30s rest
    - Aerobic: longer sets (400–1500m) at comfortable pace
    - Cool-down: easy 100–200m

    FOR TRIATHLETES:
    - Open water ≠ pool: practice sighting every 6–8 strokes
    - Wetsuit changes buoyancy — adjust body position expectations
    - Don't sprint start; build into race pace over first 100–200m
    - Focus on consistency, not speed in early training phases
    """

    static let injuries = """
    === INJURY MANAGEMENT & RED FLAGS ===

    IMMEDIATE REFERRAL (do not coach around these — refer to sports medicine):
    - Cardiac symptoms during exercise (chest pain, palpitations, unusual shortness of breath)
    - Sudden, severe joint pain (possible fracture/dislocation)
    - Stress fracture suspicion: localized bone pain, worse with activity
    - REDs signs: weight loss + performance drop + fatigue + mood changes
    - Persistent saddle/perineal symptoms (cyclists)
    - Any pain that progressively worsens over days despite rest

    RELATIVE ENERGY DEFICIENCY IN SPORT (REDs):
    - Both men and women at risk (IOC 2023)
    - Signs: fatigue, recurrent illness, stress fractures, mood changes, performance plateau
    - Action: refer to sports physician + sports dietitian

    IRON DEFICIENCY:
    - High prevalence in endurance athletes, especially women
    - Ferritin <30 µg/L often impairs performance even without anemia
    - Cannot diagnose via training data — requires blood test

    OVERTRAINING SYNDROME vs OVERREACHING:
    - Overreaching: 1–2 weeks recovery needed; expected adaptation dip
    - Overtraining: months of impaired performance; requires medical evaluation
    - Signs: declining performance despite training, mood disturbance, elevated resting HR, poor sleep
    - Treatment: rest, nutrition, professional support

    TRAINING WITH MINOR ISSUES:
    - General rule: if pain changes gait/form, don't train through it
    - DOMS (delayed onset muscle soreness): train gently through it
    - Minor tendon irritation: reduce load, avoid hills/intervals, address biomechanics
    - Never increase load while injured — maintain or reduce
    """
}
