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

// MARK: - Activity / health read handler (source-agnostic)
//
// Always registered. Serves `get_power_curve` and `get_metric_history` from the
// local store, which merges every enabled read source (Apple Health + Garmin),
// so the coach sees one unified history regardless of where it came from — plus
// `set_performance_metric`, the coach's write onto the same manual-entry path
// the Statistics screen uses (the `PerformanceMetric` catalog supplies keys,
// units and pace↔speed parsing for both). (Completed/planned workouts are
// served by the unified `get_workouts` in `WorkoutSchedulingToolHandler`.)

@MainActor
final class ActivityReadToolHandler: CoachToolHandler {
    var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "get_power_curve",
                description: "Best cycling power (max mean average, watts) per standard duration (1 s – 6 h) over a date range, from the stored per-ride power streams — all sources merged. Each point names the ride that set it. Cycling only.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "start_date": ["type": "string", "description": "Start date in YYYY-MM-DD format."],
                        "end_date": ["type": "string", "description": "End date in YYYY-MM-DD format. Defaults to today."]
                    ],
                    "required": ["start_date"]
                ]
            ),
            ToolDefinition(
                name: "get_metric_history",
                description: "Progression of physiological / wellness markers (FTP, LT pace/HR, CSS, VO2max, max HR, weight, resting HR, HRV, sleep) over time, merged across the athlete's sources. Per metric: `current` (latest value and since when it holds), `summary` (trend and range), and `history` — comma-separated \"YYYY-MM-DD value\" pairs, oldest first, consecutive repeats omitted. Recovery markers (resting HR, HRV, sleep) come daily for ranges up to 14 days and as weekly means beyond. Defaults to the last 6 months; the last 14 days when only recovery markers are requested.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "metrics": ["type": "array", "items": ["type": "string", "enum": PerformanceMetric.all.map(\.key)], "description": "Metrics to read, one or more."],
                        "start_date": ["type": "string", "description": "Start date in YYYY-MM-DD format."],
                        "end_date": ["type": "string", "description": "End date in YYYY-MM-DD format. Defaults to today."]
                    ],
                    "required": ["metrics"]
                ]
            ),
            ToolDefinition(
                name: "set_performance_metric",
                description: "Record a MEASURED physiological marker the athlete reported (a tested FTP, a measured LTHR, a weigh-in, a tested CSS). Stored as an athlete-confirmed manual value that outranks synced readings on its day; workouts scored from that date on use it. Never write estimates or guesses — only real test results and measurements.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "metric": ["type": "string", "enum": PerformanceMetric.editable.map(\.key), "description": "Metric to set."],
                        "value": ["type": "string", "description": "The measured value. A plain number for watts / bpm / kg / ml/kg/min; an m:ss pace for lactate_threshold_speed (per km) and swim_css_speed (per 100 m), e.g. \"4:35\"."],
                        "date": ["type": "string", "description": "Measurement date in YYYY-MM-DD format. Defaults to today."]
                    ],
                    "required": ["metric", "value"]
                ]
            )
        ]
    }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "get_power_curve":
            return powerCurve(arguments: arguments)
        case "get_metric_history":
            return metricHistory(arguments: arguments)
        case "set_performance_metric":
            return setPerformanceMetric(arguments: arguments)
        default:
            return "Unknown read tool: \(name)"
        }
    }

    private func powerCurve(arguments: [String: Any]) -> String {
        guard let startStr = arguments["start_date"] as? String,
              let start = DateFormatter.ymd.date(from: startStr) else {
            return "✗ Error: start_date must be a YYYY-MM-DD date."
        }
        let end: Date
        if let endStr = arguments["end_date"] as? String {
            guard let parsed = DateFormatter.ymd.date(from: endStr) else {
                return "✗ Error: end_date must be a YYYY-MM-DD date."
            }
            end = parsed
        } else {
            end = Date()
        }
        guard start <= end else { return "✗ Error: start_date must be on or before end_date." }
        let period = ["start": DateFormatter.ymd.string(from: start), "end": DateFormatter.ymd.string(from: end)]
        let records = TrainingDataStore.shared.activities(from: start, to: end)
        let points = PowerCurve.aggregate(records: records)
        guard !points.isEmpty else {
            return "No cycling power data between \(period["start"]!) and \(period["end"]!). Rides store their power curve at ingest; a per-source re-sync in Settings backfills older history."
        }
        let curve: [[String: Any]] = points.map { p in
            ["duration_seconds": p.durationSeconds,
             "duration_label": PowerCurve.durationLabel(p.durationSeconds),
             "power_w": Int(p.watts.rounded()),
             "activity_id": p.activityId,
             "activity_name": p.activityName,
             "activity_date": DateFormatter.ymd.string(from: p.date)]
        }
        return String(compactJSON: [
            "period": period,
            "curve": curve,
            "activities_with_power_data": records.count { !$0.powerCurveJSON.isEmpty }
        ])
    }

    private func metricHistory(arguments: [String: Any]) -> String {
        let requested = (arguments["metrics"] as? [Any])?.compactMap(Coerce.string) ?? []
        guard !requested.isEmpty else {
            return "✗ Error: metrics must be a non-empty array of metric keys."
        }
        var metrics: [PerformanceMetric] = []
        for key in requested {
            guard let m = PerformanceMetric.metric(for: key) else {
                return "✗ Error: unknown metric '\(key)' — must be one of: \(PerformanceMetric.all.map(\.key).joined(separator: ", "))."
            }
            metrics.append(m)
        }
        let end: Date
        if let endStr = arguments["end_date"] as? String {
            guard let parsed = DateFormatter.ymd.date(from: endStr) else {
                return "✗ Error: end_date must be a YYYY-MM-DD date."
            }
            end = parsed
        } else {
            end = Date()
        }
        let start: Date
        if let startStr = arguments["start_date"] as? String {
            guard let parsed = DateFormatter.ymd.date(from: startStr) else {
                return "✗ Error: start_date must be a YYYY-MM-DD date."
            }
            start = parsed
        } else if metrics.allSatisfy({ $0.group == .recovery }) {
            start = Calendar.current.date(byAdding: .day, value: -14, to: end)!
        } else {
            start = Calendar.current.date(byAdding: .month, value: -6, to: end)!
        }
        guard start <= end else { return "✗ Error: start_date must be on or before end_date." }
        return String(compactJSON: [
            "period": ["start": DateFormatter.ymd.string(from: start), "end": DateFormatter.ymd.string(from: end)],
            "metrics": metrics.map { metricEntry($0, start: start, end: end) }
        ])
    }

    /// One metric's response entry. `current` comes from the full series so a
    /// marker that last changed before the window still reports its live value;
    /// summary + history come from the window.
    private func metricEntry(_ metric: PerformanceMetric, start: Date, end: Date) -> [String: Any] {
        var entry: [String: Any] = ["metric": metric.key]
        if !metric.unit.isEmpty { entry["unit"] = metric.unit }
        let all = TrainingDataStore.shared.metricHistory(metric.key)
        guard !all.isEmpty else {
            entry["history"] = "no stored values — the athlete's sources have never reported this marker"
            return entry
        }
        entry["current"] = currentLine(metric, series: all)
        let window = all.filter { $0.date >= start && $0.date <= end }
        guard let first = window.first else {
            entry["history"] = "no readings in this period"
            return entry
        }
        // A flat window carries no trend — say so instead of listing repeats.
        if window.count > 1, window.allSatisfy({ metric.format($0.value) == metric.format(first.value) }) {
            entry["history"] = "unchanged in this period (\(window.count) readings)"
            return entry
        }
        let weekly = metric.group == .recovery && end.timeIntervalSince(start) > 14.5 * 86_400
        if weekly { entry["resolution"] = "weekly_mean" }
        if window.count > 1 { entry["summary"] = summaryLine(metric, window: window) }
        entry["history"] = dropRepeats(weekly ? weeklyMeans(window) : window, format: metric.format)
            .map { "\(DateFormatter.ymd.string(from: $0.date)) \(metric.format($0.value))" }
            .joined(separator: ", ")
        return entry
    }

    /// "56 since 2026-05-31 (last reading 2026-07-13)" — since = start of the
    /// value's current run, so a stable-and-confirmed marker reads differently
    /// from a stale one.
    private func currentLine(_ metric: PerformanceMetric, series: [MetricPoint]) -> String {
        let last = series.last!
        let display = metric.format(last.value)
        var since = last.date
        for p in series.reversed().dropFirst() {
            guard metric.format(p.value) == display else { break }
            since = p.date
        }
        var line = "\(display) since \(DateFormatter.ymd.string(from: since))"
        if since != last.date { line += " (last reading \(DateFormatter.ymd.string(from: last.date)))" }
        return line
    }

    /// Recovery markers: level + band. Capacity markers: first → last with the
    /// delta and (past ~6 weeks) a per-month rate, plus the window's extremes.
    private func summaryLine(_ metric: PerformanceMetric, window: [MetricPoint]) -> String {
        let values = window.map(\.value)
        let lo = values.min()!, hi = values.max()!
        if metric.group == .recovery {
            let mean = values.reduce(0, +) / Double(values.count)
            return "mean \(metric.format(mean)), low \(metric.format(lo)), high \(metric.format(hi))"
        }
        let first = window.first!, last = window.last!
        var s = "\(metric.format(first.value)) → \(metric.format(last.value))"
        if let delta = deltaText(metric, from: first, to: last) { s += " (\(delta))" }
        // Speed-stored markers display as pace, where the *smaller* speed is the
        // slower pace — "low/high" would read backwards.
        s += metric.paceDistanceM == nil
            ? ", low \(metric.format(lo)), high \(metric.format(hi))"
            : ", slowest \(metric.format(lo)), fastest \(metric.format(hi))"
        s += ", \(window.count) readings"
        return s
    }

    /// Signed first→last change, with a per-month rate once the readings span
    /// ~6 weeks (a rate over less is extrapolation). Pace-displayed markers
    /// delta in pace seconds; nil when the change rounds away.
    private func deltaText(_ metric: PerformanceMetric, from first: MetricPoint, to last: MetricPoint) -> String? {
        let months = last.date.timeIntervalSince(first.date) / (30.44 * 86_400)
        if let dist = metric.paceDistanceM {
            guard first.value > 0, last.value > 0 else { return nil }
            let deltaSec = dist / last.value - dist / first.value
            guard abs(deltaSec) >= 1 else { return nil }
            var s = String(format: "%+.0fs", deltaSec)
            if months >= 1.4 { s += String(format: ", %+.1fs/mo", deltaSec / months) }
            return s
        }
        let delta = last.value - first.value
        let formatted = metric.format(abs(delta))
        guard delta != 0, Double(formatted) ?? 0 != 0 else { return nil }
        var s = "\(delta < 0 ? "-" : "+")\(formatted)"
        if months >= 1.4 { s += String(format: ", %+.1f/mo", delta / months) }
        return s
    }

    /// Collapse daily wellness points into one mean per calendar week, labelled
    /// by the week's start day.
    private func weeklyMeans(_ points: [MetricPoint]) -> [MetricPoint] {
        let cal = Calendar.current
        var byWeek: [Date: [Double]] = [:]
        for p in points {
            let week = cal.dateInterval(of: .weekOfYear, for: p.date)?.start ?? p.date
            byWeek[week, default: []].append(p.value)
        }
        return byWeek
            .map { MetricPoint(date: $0.key, value: $0.value.reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.date < $1.date }
    }

    /// Omit points repeating the previous displayed value, always keeping the
    /// first and last so the window's endpoints stay visible.
    private func dropRepeats(_ points: [MetricPoint], format: (Double) -> String) -> [MetricPoint] {
        guard points.count > 2 else { return points }
        var kept: [MetricPoint] = [points[0]]
        for p in points.dropFirst().dropLast() where format(p.value) != format(kept.last!.value) {
            kept.append(p)
        }
        kept.append(points.last!)
        return kept
    }

    private func setPerformanceMetric(arguments: [String: Any]) -> String {
        guard let key = arguments["metric"] as? String,
              let metric = PerformanceMetric.editable.first(where: { $0.key == key }) else {
            return "✗ Error: metric must be one of: \(PerformanceMetric.editable.map(\.key).joined(separator: ", "))."
        }
        guard let raw = Coerce.string(arguments["value"]), let value = metric.parse(raw), value > 0 else {
            let hint = metric.storageUnit == "m_per_s" ? "an m:ss pace, e.g. \"4:35\"" : "a positive number"
            return "✗ Error: value for \(key) must be \(hint)."
        }
        let date: Date
        if let dateStr = arguments["date"] as? String {
            guard let parsed = DateFormatter.ymd.date(from: dateStr) else {
                return "✗ Error: date must be a YYYY-MM-DD date."
            }
            date = parsed
        } else {
            date = Date()
        }
        guard date <= Date() else { return "✗ Error: date must not be in the future — only record measurements that already happened." }
        TrainingDataStore.shared.setManualMetric(key: key, value: value, unit: metric.storageUnit, date: date)
        let display = "\(metric.format(value))\(metric.unit.isEmpty ? "" : " \(metric.unit)")"
        return String(compactJSON: [
            "message": "Recorded \(metric.title) \(display). Workouts scored from this date on use it; already-scored past workouts keep their TSS (a re-sync in Settings rescores them).",
            "metric": key,
            "value": metric.format(value),
            "date": DateFormatter.ymd.string(from: date)
        ])
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
                description: "Persist athlete profile changes, preferences, goals and sport limitations in long-term memory. Route each fact correctly: a hard limitation (injury, can't-do) is binding; a like/dislike or scheduling arrangement is a preference (add_preference), not a limitation.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Athlete name."],
                        "add_goal": ["type": "string", "description": "Goal to add."],
                        "remove_goal": ["type": "string", "description": "Goal to remove."],
                        "motivation": ["type": "string", "description": "The why behind the goals (e.g. \"first triathlon, racing with friends\"). Replaces the stored motivation."],
                        "max_weekly_hours": ["type": "integer", "description": "Maximum training hours per week."],
                        "max_hr": ["type": "integer", "description": "Maximum heart rate in bpm."],
                        "preferred_rest_day": ["type": "string", "description": "Preferred rest day."],
                        "morning_workouts": ["type": "boolean", "description": "Whether morning workouts are preferred."],
                        "indoor_trainer_available": ["type": "boolean", "description": "Whether an indoor trainer is available."],
                        "add_preference": ["type": "string", "description": "Training like/dislike or arrangement to honor by default, prefixed with the sport where relevant (e.g. \"Run: likes strides on easy runs\", \"Bike: no scheduled sessions — commute covers volume\")."],
                        "remove_preference": ["type": "string", "description": "Stored preference to remove (exact text from the PREFERENCES list)."],
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
                description: "Retrieve the current athlete profile, preferences and sport-specific progress from memory. For the season plan use get_atp.",
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
                description: "Read coaching knowledge files on specific topics: cycling, running, swimming, injuries, workouts, or trainingplan. Always call this FIRST when answering sport-specific training questions, read the 'workouts' topic before building structured workouts with add_workouts, and the 'trainingplan' topic before building or adjusting the season plan with set_atp/set_atp_event.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "topic": [
                            "type": "string",
                            "enum": ["cycling", "running", "swimming", "injuries", "workouts", "trainingplan"],
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
            return memory.contextSummary(history: TrainingDataStore.shared.performanceHistory())
        case "complete_onboarding":
            memory.markOnboardingComplete()
            return "Onboarding marked complete."
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
        if let motivation = arguments["motivation"] as? String {
            memory.updateProfile { $0.motivation = motivation }
            updates.append("motivation → \(motivation)")
        }
        if let morning = arguments["morning_workouts"] as? Bool {
            memory.updatePreferences { $0.morningWorkouts = morning }
            updates.append("morning workouts → \(morning)")
        }
        if let trainer = arguments["indoor_trainer_available"] as? Bool {
            memory.updatePreferences { $0.indoorTrainerAvailable = trainer }
            updates.append("indoor trainer → \(trainer)")
        }
        if let pref = arguments["add_preference"] as? String {
            memory.updatePreferences { p in
                if !p.trainingPreferences.contains(pref) { p.trainingPreferences.append(pref) }
            }
            updates.append("preference added: \(pref)")
        }
        if let pref = arguments["remove_preference"] as? String {
            var found = false
            memory.updatePreferences { p in
                found = p.trainingPreferences.contains(pref)
                p.trainingPreferences.removeAll { $0 == pref }
            }
            updates.append(found ? "preference removed: \(pref)" : "preference not found (pass the exact text): \(pref)")
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
        "workouts": ("WORKOUTS", "md"),
        "trainingplan": ("TRAININGSPLAN", "md")
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
                description: "Read the athlete's real-world schedule (busy/free windows) from their device calendar for a date range. Returns per-day busy minutes and the events on each day. Use ONLY when the athlete has NOT named a day/time, or when planning several days ahead. When the athlete states a time (\"tomorrow 08:00\"), schedule it directly — and treat their own calendar entries about training as plans, never as conflicts.",
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
        let json = String(compactJSON: data)
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
        return String(compactJSON: Self.dict(from: summary))
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
// so get_workouts surfaces it — independent of whether the activity came from
// Garmin or Apple Health. The matching read-side fields (feel / rpe / notes) are
// populated from Garmin directly in GarminService.formatActivityRecord.

@MainActor
final class WorkoutFeedbackToolHandler: CoachToolHandler {

    var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "log_workout_feedback",
                description: "Record the athlete's subjective feedback on a completed activity, mirroring Garmin's post-workout prompt. Pass the activity's `id` from get_workouts (status `completed`). `feel` is a 1–5 scale (1 = very weak, 3 = normal, 5 = very strong), `rpe` is the session perceived effort on a 1–10 scale (Borg CR10), and `note` is an optional free-text comment. Stored locally on the activity and surfaced by get_workouts. Provide at least one of feel / rpe / note.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "activity_id": ["type": "string", "description": "Activity id from get_workouts (status completed)."],
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
            return "✗ No completed activity found for id \(id). List it with get_workouts (status completed) first."
        }
        var saved: [String] = []
        if let feel { saved.append("feel \(feel)/5") }
        if let rpe { saved.append("RPE \(rpe)/10") }
        if note != nil { saved.append("note") }
        return "✓ Saved feedback for \(id): \(saved.joined(separator: ", "))."
    }
}

// MARK: - Garmin Tool Handler (Garmin-only read extras)
//
// Registered only when Garmin is an active READ source. The source-agnostic reads
// (`get_metric_history`/`get_power_curve` in `ActivityReadToolHandler`,
// `get_workouts` in `WorkoutSchedulingToolHandler`) and planned-workout writes are
// brand-neutral. What's left here is what is genuinely Garmin-specific: the
// settings resync.

@MainActor
final class GarminToolHandler: CoachToolHandler {
    var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "sync_user_settings",
                description: "Refresh the athlete's Garmin-derived settings & metrics: wellness (sleep/HRV/resting HR), historical performance (FTP, VO2max, thresholds, CSS, weight) and training zones. Use when the athlete says they updated values in Garmin.",
                parameters: ["type": "object", "properties": [:], "required": []]
            )
        ]
    }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        guard await GarminAuth.shared.isAuthenticated else {
            return "Garmin is not connected. Please sign in under 'Read From → Garmin' in Settings."
        }
        guard name == "sync_user_settings" else { return "Unknown Garmin tool: \(name)" }
        return await DataSyncCoordinator.shared.refreshGarminMetrics()
    }
}

// MARK: - Workout Scheduling Tool Handler (one coach API → active write target)
//
// The single, source-agnostic set of planning tools: schema + argument parsing +
// reply formatting only. The actual writes go through `DataSyncCoordinator`'s plan
// CRUD (`addPlan`/`updatePlan`/`movePlan`/`deletePlan`) — the same path the
// calendar's workout editor uses — which owns the local store (source of truth)
// and the push to the active `WorkoutSyncTarget`.

@MainActor
final class WorkoutSchedulingToolHandler: CoachToolHandler {
    /// The `workout_data` object properties, shared by `add_workouts` and
    /// `modify_workout` (they differ only in which fields are required).
    private static let workoutDataProperties: [String: Any] = [
        "name": ["type": "string", "description": "Workout name."],
        "sport": ["type": "string", "enum": ["running", "cycling", "swimming", "strength", "yoga", "cardio", "other"], "description": "Workout sport."],
        "duration_minutes": ["type": "integer", "description": "Total duration in minutes (time goal). Give this and/or distance_meters, or explicit steps."],
        "distance_meters": ["type": "number", "description": "Total distance in meters (distance goal)."],
        "pool_length": ["type": "integer", "description": "Pool length in meters for swim workouts (default 50)."],
        "description": ["type": "string", "description": "Workout description."],
        "include_warmup": ["type": "boolean", "description": "Add a warm-up block when no explicit steps are given (default true)."],
        "include_cooldown": ["type": "boolean", "description": "Add a cool-down block when no explicit steps are given (default true)."],
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
                    "target_type": ["type": "string", "enum": ["no_target", "heart_rate", "power", "pace", "speed", "cadence"], "description": "Intensity target type (units/bands in read_knowledge('workouts') §3)."],
                    "target_low": ["type": "number", "description": "Single target value; the app auto-expands it into a band."],
                    "target_high": ["type": "number", "description": "Optional explicit upper bound (overrides the auto band)."]
                ]
            ]
        ]
    ]

    /// Emits a chat card for every successful plan mutation — the chat renders
    /// it inline, so the model doesn't restate the workout in prose. Calendar
    /// editor mutations bypass this handler and never emit cards.
    private let onCard: (ChatCard) -> Void

    init(onCard: @escaping (ChatCard) -> Void) {
        self.onCard = onCard
    }

    var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "get_workouts",
                description: "List the athlete's workouts, lean and TSS-focused. `status` selects what comes back: \"completed\" (finished activities, each with its `tss` and how it was derived `tss_basis`), \"planned\" (open, editable sessions — each carries the `workout_id` + `workout_data` that modify_workout / move_workout / delete_workout need), or \"all\" (both). Optional `sport` filter and `from`/`to` range (defaults: completed → last 14 days, planned → next 28). `detailed: true` adds the per-lap/interval breakdown for completed workouts (capped to 5 rows). (For the athlete's real-world busy/free time, use read_calendar_availability instead.)",
                parameters: [
                    "type": "object",
                    "properties": [
                        "status": ["type": "string", "enum": ["completed", "planned", "all"], "description": "Which workouts to return. Default \"all\"."],
                        "sport": ["type": "string", "enum": ["running", "cycling", "swimming", "strength"], "description": "Optional sport filter."],
                        "from": ["type": "string", "description": "Start date in YYYY-MM-DD format (optional)."],
                        "to": ["type": "string", "description": "End date in YYYY-MM-DD format (optional)."],
                        "limit": ["type": "integer", "description": "Max rows per section. Default 20; forced to 5 when detailed."],
                        "detailed": ["type": "boolean", "description": "Include the per-lap breakdown of completed workouts (default false)."]
                    ],
                    "required": []
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
        switch name {
        case "get_workouts":
            return await DataSyncCoordinator.shared.workouts(
                status: (arguments["status"] as? String) ?? "all",
                sport: arguments["sport"] as? String,
                from: (arguments["from"] as? String).flatMap(DateFormatter.ymd.date(from:)),
                to: (arguments["to"] as? String).flatMap(DateFormatter.ymd.date(from:)),
                limit: Coerce.int(arguments["limit"]) ?? 20,
                detailed: arguments["detailed"] as? Bool ?? false
            )
        case "add_workouts":
            guard let items = arguments["workouts"] as? [[String: Any]], !items.isEmpty else {
                return "✗ Error: workouts is missing or empty."
            }
            return await addWorkoutsBatch(items)
        case "modify_workout":
            return await modify(arguments)
        case "move_workout":
            return await move(arguments)
        case "delete_workout":
            return await delete(arguments)
        default:
            return "Unknown scheduling tool: \(name)"
        }
    }

    // MARK: - add_workouts

    private func addWorkoutsBatch(_ items: [[String: Any]]) async -> String {
        var lines: [String] = []
        var ok = 0
        for (i, item) in items.enumerated() {
            let dateStr = item["date"] as? String ?? ""
            guard let raw = item["workout_data"] as? [String: Any] else {
                lines.append("- \(dateStr.isEmpty ? "item \(i + 1)" : dateStr) — ✗ missing workout_data")
                continue
            }
            guard let date = DateFormatter.ymd.date(from: dateStr) else {
                lines.append("- \(dateStr) — ✗ invalid date (use YYYY-MM-DD)")
                continue
            }
            let outcome = await DataSyncCoordinator.shared.addPlan(workoutData: raw, date: date)
            // The plan exists locally even when the target push failed — card either way.
            onCard(.workout(id: outcome.planId, caption: "Scheduled"))
            if outcome.pushed {
                ok += 1
                let suffix = outcome.notes.isEmpty ? "" : " (\(outcome.notes.joined(separator: "; ")))"
                lines.append("- \(dateStr) \(outcome.name) → \(outcome.targetName)\(suffix) [id: \(outcome.planId)]")
            } else {
                lines.append("- \(dateStr) \(outcome.name) — saved locally, \(outcome.targetName) push failed: \(outcome.pushMessage) [id: \(outcome.planId)]")
            }
        }
        let mark = ok == items.count ? "✓ " : ""
        return (["\(mark)Scheduled \(ok)/\(items.count) workouts to \(AppSettings.storedWriteTarget().displayName)."] + lines)
            .joined(separator: "\n")
    }

    // MARK: - modify_workout

    private func modify(_ arguments: [String: Any]) async -> String {
        guard let workoutId = Coerce.string(arguments["workout_id"]), !workoutId.isEmpty,
              let rawWorkout = arguments["workout_data"] as? [String: Any] else {
            return "✗ Error: workout_id and workout_data are required."
        }
        let before = DataSyncCoordinator.shared.plannedSnapshot(id: workoutId)
        guard let outcome = await DataSyncCoordinator.shared.updatePlan(id: workoutId, workoutData: rawWorkout) else {
            return "✗ No planned workout found for id \(workoutId). List it with get_workouts first."
        }
        // Diff the stored before/after states — not the tool arguments — so the
        // card shows what actually applied after WorkoutNormalizer.
        if let before, let after = DataSyncCoordinator.shared.plannedSnapshot(id: outcome.planId) {
            let changes = WorkoutDiff.changes(before: before.workoutData, after: after.workoutData)
            if !changes.isEmpty {
                onCard(.workoutDiff(id: outcome.planId, name: after.name, caption: "Updated", changes: changes))
            }
        }
        var msg = outcome.pushed
            ? "✓ Updated '\(outcome.name)' on \(outcome.targetName). [id: \(outcome.planId)]"
            : "✓ Updated locally; \(outcome.targetName) push failed: \(outcome.pushMessage) [id: \(outcome.planId)]"
        if !outcome.notes.isEmpty { msg += "\nℹ️ Applied defaults & adjustments:\n" + outcome.notes.map { "- \($0)" }.joined(separator: "\n") }
        return msg
    }

    // MARK: - move_workout

    private func move(_ arguments: [String: Any]) async -> String {
        guard let workoutId = Coerce.string(arguments["workout_id"]), !workoutId.isEmpty,
              let toDate = arguments["to_date"] as? String, let date = DateFormatter.ymd.date(from: toDate) else {
            return "✗ Error: workout_id and a valid to_date (YYYY-MM-DD) are required."
        }
        let before = DataSyncCoordinator.shared.plannedSnapshot(id: workoutId)
        guard let outcome = await DataSyncCoordinator.shared.movePlan(id: workoutId, to: date) else {
            return "✗ No planned workout found for id \(workoutId)."
        }
        if let before {
            onCard(.workoutDiff(id: outcome.planId, name: outcome.name, caption: "Moved",
                                changes: ["Date: \(cardDate(before.date)) → \(cardDate(date))"]))
        }
        return outcome.pushed
            ? "✓ Moved '\(outcome.name)' to \(toDate) on \(outcome.targetName). [id: \(outcome.planId)]"
            : "✓ Moved locally; \(outcome.targetName) push failed: \(outcome.pushMessage) [id: \(outcome.planId)]"
    }

    // MARK: - delete_workout

    private func delete(_ arguments: [String: Any]) async -> String {
        guard let workoutId = Coerce.string(arguments["workout_id"]), !workoutId.isEmpty else {
            return "✗ Error: workout_id is required."
        }
        // Snapshot first — after the delete there is nothing left to describe.
        let before = DataSyncCoordinator.shared.plannedSnapshot(id: workoutId)
        // Delete from every provider the plan reached (not just the active write
        // target), then drop it locally.
        await DataSyncCoordinator.shared.deletePlan(id: workoutId)
        if let before {
            onCard(.workoutDeleted(name: before.name, sport: before.sport, date: before.date))
        }
        return "✓ Deleted workout \(workoutId)."
    }

    private func cardDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
