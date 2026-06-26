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
    var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "get_health_metrics",
                description: "Fetch recovery data for the last N days: sleep (duration + score), resting heart rate and overnight HRV, with a short-term resting-HR trend. Secondary signals — weigh against the load/form trend, not in isolation.",
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
            // Served from the local wellness time series (DB-backed, source-agnostic).
            let days = arguments["days"] as? Int ?? 7
            return await DataSyncCoordinator.shared.healthMetrics(source: .appleHealth, days: days)
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
                description: "Persist athlete profile changes, preferences, goals and sport limitations in long-term memory.",
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
                name: "complete_onboarding",
                description: "Mark onboarding as finished. Call this once the key athlete info (name, goals, weekly hours, max HR) has been gathered and saved via update_athlete_profile. After this the onboarding flow is no longer shown.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ),
            ToolDefinition(
                name: "read_knowledge",
                description: "Read coaching knowledge files on specific topics: cycling, running, swimming, injuries, or workouts. Always call this FIRST when answering sport-specific training questions, and read the 'workouts' topic before building structured workouts with add_workouts.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "topic": [
                            "type": "string",
                            "enum": ["cycling", "running", "swimming", "injuries", "workouts"],
                            "description": "The topic to read."
                        ]
                    ],
                    "required": ["topic"]
                ]
            ),
            ToolDefinition(
                name: "set_training_plan",
                description: "Build or replace the athlete's complete periodized training plan in one call: the target event, its date, and an ordered list of phases (e.g. base → build → peak → taper) leading up to the event. Each phase has a date range, a focus, and per-sport weekly targets (distance and/or TSS). Use this to generate a full plan end-to-end; for single-field tweaks use update_athlete_profile. Replaces any existing phases.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "target_event": ["type": "string", "description": "Primary target race or event."],
                        "event_date": ["type": "string", "description": "Event date in YYYY-MM-DD format."],
                        "phases": [
                            "type": "array",
                            "description": "Ordered training phases from now until the event.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "name": [
                                        "type": "string",
                                        "enum": ["Prep", "Base", "Build", "Peak", "Taper", "Race", "Recovery", "Transition"],
                                        "description": "Phase type."
                                    ],
                                    "start_date": ["type": "string", "description": "Phase start in YYYY-MM-DD format."],
                                    "end_date": ["type": "string", "description": "Phase end in YYYY-MM-DD format."],
                                    "focus": ["type": "string", "description": "Main training focus of this phase."],
                                    "sport_targets": [
                                        "type": "object",
                                        "description": "Per-sport weekly targets for this phase.",
                                        "properties": [
                                            "swimming": Self.sportTargetSchema,
                                            "cycling": Self.sportTargetSchema,
                                            "running": Self.sportTargetSchema,
                                            "strength": Self.sportTargetSchema
                                        ]
                                    ]
                                ],
                                "required": ["name", "start_date", "end_date"]
                            ]
                        ]
                    ],
                    "required": ["phases"]
                ]
            )
        ]
    }

    /// Reusable JSON-Schema fragment for a single sport's weekly target.
    private static let sportTargetSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "weekly_distance_km": ["type": "number", "description": "Target weekly distance in kilometers."],
            "weekly_tss": ["type": "integer", "description": "Target weekly TSS (training stress) for this sport."]
        ]
    ]

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "update_athlete_profile":
            return updateProfile(arguments: arguments)
        case "get_athlete_profile":
            return memory.contextSummary(performance: TrainingDataStore.shared.latestSnapshot())
        case "complete_onboarding":
            memory.markOnboardingComplete()
            return "Onboarding marked complete."
        case "read_knowledge":
            let topic = arguments["topic"] as? String ?? ""
            return knowledgeSummary(for: topic)
        case "set_training_plan":
            return setTrainingPlan(arguments: arguments)
        default:
            return "Unknown profile tool: \(name)"
        }
    }

    private func setTrainingPlan(arguments: [String: Any]) -> String {
        let rawPhases = arguments["phases"] as? [[String: Any]] ?? []
        let phases = rawPhases.compactMap(Phase.init(from:))
        let dropped = rawPhases.count - phases.count

        memory.updateTrainingPlan { plan in
            if let ev = arguments["target_event"] as? String, !ev.isEmpty { plan.targetEvent = ev }
            if let dt = arguments["event_date"] as? String, !dt.isEmpty { plan.eventDate = dt }
            if !phases.isEmpty {
                plan.phases = phases.sorted {
                    ($0.start() ?? .distantPast) < ($1.start() ?? .distantPast)
                }
                // Keep the legacy flat current_phase in sync with the new array.
                if let current = plan.phase() {
                    plan.currentPhase = current.name.rawValue
                    plan.phaseStartDate = current.startDate
                    plan.phaseEndDate = current.endDate
                }
            }
        }

        var msg = "Training plan saved with \(phases.count) phase(s)."
        if dropped > 0 {
            msg += " \(dropped) phase(s) were ignored because of an invalid name "
            msg += "(use exactly one of: Prep, Base, Build, Peak, Taper, Race, Recovery, Transition)."
        }
        return msg
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

    /// Maps a topic to its knowledge file (in `Assets/Knowledge/`).
    private static let knowledgeFiles: [String: (resource: String, ext: String)] = [
        "cycling":  ("CYCLING",  "md"),
        "running":  ("RUNNING",  "md"),
        "swimming": ("SWIMMING", "md"),
        "injuries": ("INJURIES", "MD"),
        "workouts": ("WORKOUTS", "md")
    ]

    private func knowledgeSummary(for topic: String) -> String {
        guard let entry = Self.knowledgeFiles[topic] else {
            let available = Self.knowledgeFiles.keys.sorted().joined(separator: ", ")
            return "Unknown topic: \(topic). Available: \(available)."
        }

        // Synchronized groups copy the .md files into the bundle's resource
        // root (flattened), so look them up by name without a subdirectory.
        guard let url = Bundle.main.url(forResource: entry.resource, withExtension: entry.ext),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "Knowledge file \(entry.resource).\(entry.ext) is not bundled."
        }
        return contents
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
        let start = (arguments["start_date"] as? String).flatMap(DateFormatter.ymd.date(from:)) ?? today
        let defaultEnd = cal.date(byAdding: .day, value: 7, to: start) ?? start
        let end = (arguments["end_date"] as? String).flatMap(DateFormatter.ymd.date(from:)) ?? defaultEnd

        let days = calendar.availability(from: start, to: max(start, end))
        let payload: [[String: Any]] = days.map { day in
            [
                "date": DateFormatter.ymd.string(from: day.date),
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
            "range": ["start": DateFormatter.ymd.string(from: start), "end": DateFormatter.ymd.string(from: max(start, end))]
        ]
        let json = String(prettyJSON: data)
        return "✓ Calendar availability for \(payload.count) day(s)\n\(json)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

// MARK: - Training Load Tool Handler
//
// Always-on and source-agnostic: the injury-relevant *derived* layer on top of
// the local store, computed by `TrainingLoadAnalytics` so it reads the same
// whether activities came from Garmin or Apple Health. Replaces Garmin's
// `get_training_status` (which returned a single, Garmin-only ACWR number — the
// framing INJURIES.MD / CYCLING.md §5 explicitly advise against).

@MainActor
final class TrainingLoadToolHandler: CoachToolHandler {

    var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "get_training_load",
                description: "Source-agnostic training-load & injury-risk summary derived from stored activities (works for both Garmin and Apple Health). Per sport: weekly volume and week-over-week ramp rate, longest session in the last 7 days vs the prior 30-day longest (the long-session progression check), long-session share of weekly volume, and average sessions/week. Plus acute (ATL, 7d) and chronic (CTL, 42d) load reported SEPARATELY with a week-over-week TSS step change — deliberately not a single ACWR ratio. Use it to judge ramp/overload and long-session spikes before adjusting the plan.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "weeks": ["type": "integer", "description": "How many recent weeks to analyse (3–12). Default 6."]
                    ],
                    "required": []
                ]
            )
        ]
    }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        guard name == "get_training_load" else { return "Unknown training-load tool: \(name)" }
        let weeks = min(max((arguments["weeks"] as? Int) ?? 6, 3), 12)
        let summary = TrainingLoadAnalytics.summary(weeks: weeks)
        guard summary.hasData else {
            return "No training-load data yet — the local activity history is empty. Sync activities first."
        }
        return String(prettyJSON: Self.dict(from: summary))
    }

    private static func dict(from s: TrainingLoadSummary) -> [String: Any] {
        var sports: [[String: Any]] = []
        for m in s.perSport {
            var d: [String: Any] = [
                "sport": m.family.displayName.lowercased(),
                "current_week": [
                    "distance_km": round1(m.currentWeekDistanceKm),
                    "duration_minutes": round1(m.currentWeekDurationMinutes),
                    "sessions": m.currentWeekSessions
                ],
                "baseline_weekly_avg": [
                    "distance_km": round1(m.baselineWeeklyDistanceKm),
                    "duration_minutes": round1(m.baselineWeeklyDurationMinutes)
                ],
                "avg_sessions_per_week": round1(m.avgSessionsPerWeek)
            ]
            if let r = m.rampRate { d["ramp_rate_pct"] = round1(r * 100) }
            if let r = m.recentLongest { d["longest_last_7d"] = longestDict(r) }
            if let b = m.baselineLongest { d["longest_prior_30d"] = longestDict(b) }
            if let p = m.longestProgressionRatio { d["longest_progression_pct"] = round1((p - 1) * 100) }
            if let share = m.longSessionShare { d["long_session_share_pct"] = round1(share * 100) }
            sports.append(d)
        }
        var out: [String: Any] = ["weeks": s.weeks, "per_sport": sports]
        if let l = s.load {
            out["load"] = [
                "fatigue_atl_7d": round1(l.atl),
                "fitness_ctl_42d": round1(l.ctl),
                "form_tsb": round1(l.tsb),
                "current_week_tss": round1(l.currentWeekTSS),
                "prior_week_tss": round1(l.priorWeekTSS),
                "week_over_week_tss_delta": round1(l.weekOverWeekTSSDelta),
                "note": "Acute (ATL) and chronic (CTL) are reported separately on purpose — do not collapse into an ACWR gate (Impellizzeri 2020/21). Watch for step changes."
            ]
        }
        return out
    }

    private static func longestDict(_ s: LongestSession) -> [String: Any] {
        [
            "distance_km": round1(s.distanceKm),
            "duration_minutes": round1(s.durationMinutes),
            "date": DateFormatter.ymd.string(from: s.date),
            "name": s.name
        ]
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}

// MARK: - Workout Feedback Tool Handler
//
// Always-on and source-agnostic. Lets the coach record the athlete's subjective
// post-session feedback (Garmin's "How did you feel?" + perceived-effort prompt)
// against a completed activity, stored as a local override on the activity record
// so get_activities surfaces it — independent of whether the activity came from
// Garmin or Apple Health. The matching read-side fields (feel / rpe / notes) are
// populated from Garmin directly in GarminService.formatActivityRecord.

@MainActor
final class WorkoutFeedbackToolHandler: CoachToolHandler {

    var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "log_workout_feedback",
                description: "Record the athlete's subjective feedback on a completed activity, mirroring Garmin's post-workout prompt. Pass the activity's `id` from get_activities. `feel` is a 1–5 scale (1 = very weak, 3 = normal, 5 = very strong), `rpe` is the session perceived effort on a 1–10 scale (Borg CR10), and `note` is an optional free-text comment. Stored locally on the activity and returned by get_activities. Provide at least one of feel / rpe / note.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "activity_id": ["type": "string", "description": "Activity id from get_activities."],
                        "feel": ["type": "integer", "description": "How the session felt, 1–5 (1 very weak … 5 very strong)."],
                        "rpe": ["type": "integer", "description": "Session perceived effort, 1–10 (Borg CR10)."],
                        "note": ["type": "string", "description": "Optional free-text comment on the session."]
                    ],
                    "required": ["activity_id"]
                ]
            )
        ]
    }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        guard name == "log_workout_feedback" else { return "Unknown feedback tool: \(name)" }
        guard let id = Coerce.string(arguments["activity_id"]), !id.isEmpty else {
            return "✗ Error: activity_id is required."
        }
        let feel = Coerce.int(arguments["feel"])
        let rpe = Coerce.int(arguments["rpe"])
        let note = (Coerce.string(arguments["note"])?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        guard feel != nil || rpe != nil || note != nil else {
            return "✗ Error: provide at least one of feel (1–5), rpe (1–10), or note."
        }
        if let feel, !(1...5).contains(feel) { return "✗ Error: feel must be between 1 and 5." }
        if let rpe, !(1...10).contains(rpe) { return "✗ Error: rpe must be between 1 and 10." }

        let ok = TrainingDataStore.shared.setWorkoutFeedback(activityId: id, feel: feel, rpe: rpe, note: note)
        guard ok else {
            return "✗ No completed activity found for id \(id). List it with get_activities first."
        }
        var saved: [String] = []
        if let feel { saved.append("feel \(feel)/5") }
        if let rpe { saved.append("RPE \(rpe)/10") }
        if note != nil { saved.append("note") }
        return "✓ Saved feedback for \(id): \(saved.joined(separator: ", "))."
    }
}

// MARK: - Garmin Tool Handler
//
// Tool names mirror the HealthKit handler (get_activities / get_health_metrics)
// so the coach is agnostic to the active data source.

@MainActor
final class GarminToolHandler: CoachToolHandler {
    private let memory: CoachMemory
    private let service = GarminService.shared

    init(memory: CoachMemory) {
        self.memory = memory
    }

    /// The `workout_data` object properties, shared by `add_workout` and
    /// `modify_workout` (they differ only in which fields are required).
    private static let workoutDataProperties: [String: Any] = [
        "name": ["type": "string", "description": "Workout name."],
        "sport": ["type": "string", "enum": ["running", "cycling", "swimming", "strength", "yoga", "cardio", "other"], "description": "Workout sport."],
        "duration_minutes": ["type": "integer", "description": "Total duration in minutes. Provide this and/or distance_meters (or explicit steps) — a workout can be time-based, distance-based, or both."],
        "distance_meters": ["type": "number", "description": "Total distance in meters. Use for a distance goal (e.g. a 10 km run) instead of, or alongside, duration_minutes."],
        "pool_length": ["type": "integer", "description": "Pool length in meters for swim workouts (default 50)."],
        "description": ["type": "string", "description": "Workout description."],
        "include_warmup": ["type": "boolean", "description": "Include a warm-up block when no explicit steps are given (default true)."],
        "include_cooldown": ["type": "boolean", "description": "Include a cool-down block when no explicit steps are given (default true)."],
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
                    "repeat_count": ["type": "integer", "description": "Iterations for repeat blocks (default 4)."],
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
                    "target_type": ["type": "string", "enum": ["no_target", "heart_rate", "power", "pace", "speed", "cadence"], "description": "Intensity target type. Units: pace = seconds per km (seconds per 100 m for swim), speed = km/h, heart_rate = bpm, power = watts, cadence = rpm (cycling) or spm (run/swim)."],
                    "target_low": ["type": "number", "description": "Target value. Pass a single value here (and/or in target_high) and the app expands it into a sensible band automatically — e.g. pace 300 (5:00/km) → 4:40–5:10."],
                    "target_high": ["type": "number", "description": "Optional explicit upper bound. Provide a distinct target_low/target_high pair only to override the automatic band."]
                ]
            ]
        ]
    ]

    var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "get_health_metrics",
                description: "Fetch recovery data for the last N days: sleep (duration + score), resting heart rate and overnight HRV, with a short-term resting-HR trend. Secondary signals — weigh against the load/form trend, not in isolation.",
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
                name: "get_workouts",
                description: "List the athlete's workouts for a date range. Returns `scheduled` (planned, editable workouts — each carries a `workout_id` and a `workout_data` object you can pass straight to modify_workout) and `completed` (finished activities). This is the source for the `workout_id` that modify_workout, move_workout, and delete_workout need. (For the athlete's real-world busy/free time, use read_calendar_availability instead.)",
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
                    "properties": ["workout_id": ["type": "string", "description": "Workout ID from get_workouts."]],
                    "required": ["workout_id"]
                ]
            ),
            ToolDefinition(
                name: "add_workouts",
                description: "Create and schedule one or more structured workouts in a single call — one session is a one-element list, a whole week is several. Call read_knowledge('workouts') first for the schema, target units, and conventions. The app fills sensible defaults and widens single-value intensity targets into bands automatically — pass one value per target, don't fake zero-width ranges. Items are scheduled independently; the result reports each one.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "workouts": [
                            "type": "array",
                            "description": "Workouts to create. Each item is one session.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "workout_data": [
                                        "type": "object",
                                        "description": "Workout definition object. Give duration_minutes and/or distance_meters (or explicit steps).",
                                        "properties": Self.workoutDataProperties,
                                        "required": ["name", "sport"]
                                    ],
                                    "date": ["type": "string", "description": "Target date in YYYY-MM-DD format."]
                                ],
                                "required": ["workout_data", "date"]
                            ]
                        ]
                    ],
                    "required": ["workouts"]
                ]
            ),
            ToolDefinition(
                name: "move_workout",
                description: "Reschedule a workout to a new date by its ID (from get_workouts). The content is unchanged — use modify_workout to edit content.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "workout_id": ["type": "string", "description": "Workout ID from get_workouts."],
                        "to_date": ["type": "string", "description": "Target date in YYYY-MM-DD format."],
                        "from_date": ["type": "string", "description": "Optional current date (from get_workouts) — speeds up the lookup."]
                    ],
                    "required": ["workout_id", "to_date"]
                ]
            ),
            ToolDefinition(
                name: "modify_workout",
                description: "Edit an existing scheduled workout's content in place (name, description, steps, targets, duration). Get the workout_id and its current workout_data from get_workouts first. Provide `steps` in workout_data to replace the structure (targets get banded just like add_workouts); provide only top-level fields (e.g. name/description) to tweak without resending steps. Date changes use move_workout, not this.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "workout_id": ["type": "string", "description": "Workout ID from get_workouts."],
                        "workout_data": [
                            "type": "object",
                            "description": "Fields to change. All optional: include `steps` to replace the structure, or just the top-level fields you want to edit.",
                            "properties": Self.workoutDataProperties,
                            "required": []
                        ]
                    ],
                    "required": ["workout_id", "workout_data"]
                ]
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
                count: Coerce.int(arguments["count"]) ?? 10,
                days: Coerce.int(arguments["days"])
            )
        }

        let connected = await GarminAuth.shared.isAuthenticated
        guard connected else {
            return "Garmin is not connected. Please sign in under 'Garmin Connect' in Settings."
        }

        switch name {
        case "get_health_metrics":
            return await DataSyncCoordinator.shared.healthMetrics(source: .garmin, days: Coerce.int(arguments["days"]) ?? 7)
        case "get_power_curve":
            let durations = (arguments["durations_seconds"] as? [Any])?.compactMap { Coerce.int($0) }
            return await service.getPowerCurve(
                startDate: arguments["start_date"] as? String ?? "",
                endDate: arguments["end_date"] as? String ?? "",
                sport: arguments["sport"] as? String ?? "cycling",
                durationsSeconds: durations
            )
        case "get_workouts":
            return await service.getWorkouts(
                startDate: arguments["start_date"] as? String ?? "",
                endDate: arguments["end_date"] as? String ?? ""
            )
        case "delete_workout":
            let workoutId = Coerce.string(arguments["workout_id"]) ?? ""
            let result = await service.deleteWorkout(workoutId: workoutId)
            if result.hasPrefix("✓") {
                TrainingDataStore.shared.deleteScheduledWorkout(id: "garmin:\(workoutId)")
            }
            return result
        case "add_workouts":
            guard let items = arguments["workouts"] as? [[String: Any]], !items.isEmpty else {
                return "✗ Error: workouts is missing or empty."
            }
            return await addWorkoutsBatch(items)
        case "move_workout":
            guard let workoutId = Coerce.string(arguments["workout_id"]), !workoutId.isEmpty else {
                return "✗ Error: workout_id is required."
            }
            let result = await service.moveWorkout(
                workoutId: workoutId,
                toDate: arguments["to_date"] as? String ?? "",
                fromDate: arguments["from_date"] as? String
            )
            applyMovedWorkout(result)
            return result
        case "modify_workout":
            guard let workoutId = Coerce.string(arguments["workout_id"]), !workoutId.isEmpty,
                  let rawWorkout = arguments["workout_data"] as? [String: Any] else {
                return "✗ Error: workout_id and workout_data are required."
            }
            // Normalize only when the structure is being replaced — a top-level-only
            // edit (e.g. description) keeps the existing steps untouched.
            let editsSteps = rawWorkout["steps"] != nil
            let (workoutData, notes) = editsSteps
                ? WorkoutNormalizer.normalize(rawWorkout)
                : (rawWorkout, [])
            let result = await service.modifyWorkout(workoutId: workoutId, workoutData: workoutData)
            ingestModifiedWorkout(result, workoutData: workoutData, editsSteps: editsSteps)
            return appendDefaultsNotes(to: result, notes: notes)
        case "sync_user_settings":
            // Full refresh: wellness + historical-performance series + training zones.
            return await DataSyncCoordinator.shared.refreshGarminMetrics()
        default:
            return "Unknown Garmin tool: \(name)"
        }
    }

    // MARK: - add_workouts batch

    /// Schedule a batch of workouts independently, tolerating per-item failures,
    /// and return one aggregate summary the model can relay. Each item reuses the
    /// same normalize → addWorkout → mirror path as a single add.
    private func addWorkoutsBatch(_ items: [[String: Any]]) async -> String {
        var lines: [String] = []
        var ok = 0
        for (i, item) in items.enumerated() {
            let date = item["date"] as? String ?? ""
            guard let raw = item["workout_data"] as? [String: Any] else {
                lines.append("- \(date.isEmpty ? "item \(i + 1)" : date) — ✗ missing workout_data")
                continue
            }
            let (workoutData, notes) = WorkoutNormalizer.normalize(raw)
            let name = workoutData["name"] as? String ?? "Workout"
            let result = await service.addWorkout(workoutData: workoutData, date: date)
            if result.hasPrefix("✓") {
                ok += 1
                ingestAddedWorkout(result, workoutData: workoutData)
                let suffix = notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))"
                lines.append("- \(date) \(name) — ok\(suffix)")
            } else {
                let reason = result.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? result
                lines.append("- \(date) \(name) — ✗ \(reason)")
            }
        }
        let mark = ok == items.count ? "✓ " : ""
        let header = "\(mark)Scheduled \(ok)/\(items.count) workouts."
        return ([header] + lines).joined(separator: "\n")
    }

    // MARK: - Local scheduled-workout mirror
    //
    // Keep the local scheduled-workout store in step with the coach's Garmin
    // scheduling actions so the dashboard/calendar update immediately, without
    // waiting for the next full calendar sync.

    /// Append a transparent summary of the defaults/adjustments WorkoutNormalizer
    /// applied, so the coach can relay exactly what was scheduled. Only on success.
    private func appendDefaultsNotes(to result: String, notes: [String]) -> String {
        guard result.hasPrefix("✓"), !notes.isEmpty else { return result }
        return result + "\n\nℹ️ Applied defaults & adjustments:\n" + notes.map { "- \($0)" }.joined(separator: "\n")
    }

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
              let date = DateFormatter.ymd.date(from: dateStr) else { return }
        let minutes = (workoutData["duration_minutes"] as? NSNumber)?.doubleValue ?? 0
        let family = SportFamily(sportKey: data["sport"] as? String ?? "other")
        // Compute an intensity-based planned TSS from the structured steps when the
        // coach provided them; nil falls back to the duration heuristic at read time.
        let targetTSS = PlannedTSS.estimate(
            compactSteps: workoutData["steps"] as? [[String: Any]] ?? [],
            family: family,
            thresholds: TrainingDataStore.shared.latestSnapshot()
        )
        TrainingDataStore.shared.ingestScheduled([
            IngestedScheduledWorkout(
                id: "garmin:\(workoutId)",
                source: "garmin",
                date: date,
                sport: data["sport"] as? String ?? "other",
                name: data["name"] as? String ?? workoutData["name"] as? String ?? "Scheduled Workout",
                targetDurationMinutes: minutes,
                targetTSS: targetTSS,
                notes: workoutData["description"] as? String ?? ""
            )
        ])
    }

    /// Reflect a Garmin in-place edit locally (content only — the date is preserved).
    private func ingestModifiedWorkout(_ result: String, workoutData: [String: Any], editsSteps: Bool) {
        guard let data = resultData(result),
              let workoutId = data["workout_id"], !(workoutId is NSNull) else { return }
        // Recompute planned TSS only when the structure changed; `.none` leaves the
        // stored value untouched, while a fresh estimate (possibly nil) replaces it.
        let targetTSS: Double??
        if editsSteps {
            targetTSS = PlannedTSS.estimate(
                compactSteps: workoutData["steps"] as? [[String: Any]] ?? [],
                family: SportFamily(sportKey: data["sport"] as? String ?? "other"),
                thresholds: TrainingDataStore.shared.latestSnapshot()
            )
        } else {
            targetTSS = nil
        }
        TrainingDataStore.shared.updateScheduledContent(
            id: "garmin:\(workoutId)",
            sport: data["sport"] as? String,
            name: data["name"] as? String,
            targetDurationMinutes: (workoutData["duration_minutes"] as? NSNumber)?.doubleValue,
            targetTSS: targetTSS,
            notes: workoutData["description"] as? String
        )
    }

    /// Reflect a Garmin move locally by shifting the record to its new date.
    private func applyMovedWorkout(_ result: String) {
        guard let data = resultData(result),
              let workoutId = data["workout_id"], !(workoutId is NSNull),
              let toStr = data["to_date"] as? String,
              let date = DateFormatter.ymd.date(from: toStr) else { return }
        TrainingDataStore.shared.moveScheduledWorkout(id: "garmin:\(workoutId)", to: date)
    }
}
