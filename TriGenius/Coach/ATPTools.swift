import Foundation

// MARK: - ATP tool handler
//
// The coach's window onto the Annual Training Plan (the deterministic season plan
// in SwiftData). Composable: `set_atp` sets the methodology/volume config,
// `set_atp_event`/`delete_atp_event` manage the season's races, and
// `pin_atp_week`/`unpin_atp_week` hold a specific week's TSS. After any change the
// engine re-periodizes; the coach supplies events + params, never weekly numbers.

@MainActor
final class ATPToolHandler: CoachToolHandler {

    private var store: TrainingDataStore { .shared }

    var definitions: [ToolDefinition] {
        let eventIDProp: [String: Any] = ["type": "string", "description": "The event's id (from get_atp)."]
        let weekProp: [String: Any] = ["type": "string", "description": "Any date within the target week (YYYY-MM-DD); snapped to that week's Monday."]
        return [
            ToolDefinition(
                name: "get_atp",
                description: "Read the Annual Training Plan (ATP) as JSON: methodology, events (with ids), pinned weeks, the current period + this week's TSS target, and the next A race's projected fitness (CTL) — enough to discuss or adjust the season plan. Pass `detail: true` only when you need the full week-by-week upcoming schedule.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "detail": ["type": "boolean", "description": "Include the week-by-week upcoming schedule (default false)."]
                    ],
                    "required": []
                ]
            ),
            ToolDefinition(
                name: "set_atp",
                description: "Set or update the ATP's season config (methodology + volume inputs). Call read_knowledge('trainingplan') first when seeding a new plan or choosing a methodology/ramp rate — it covers starting-CTL estimates, realistic volume ranges, and how to individualize recovery_cycle/max_ramp_rate. Merges with the existing config — only the fields you pass change. Does NOT touch events or week pins (use set_atp_event / pin_atp_week). methodology is required the first time. The engine re-periodizes from the config + events.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "methodology": ["type": "string", "enum": ["weekly_tss", "target_ctl"],
                                        "description": "weekly_tss: spread a season weekly-average TSS across the plan. target_ctl: back-solve TSS so projected CTL reaches each A race's target_ctl."],
                        "start_date": ["type": "string", "description": "Plan anchor date (YYYY-MM-DD). Defaults to today on first creation."],
                        "recovery_cycle": ["type": "integer", "description": "An easier recovery week every N weeks (3 or 4)."],
                        "weekly_average_tss": ["type": "number", "description": "Season average weekly TSS (weekly_tss methodology)."],
                        "max_ramp_rate": ["type": "number", "description": "Max sustainable weekly CTL increase (target_ctl methodology)."],
                        "starting_ctl": ["type": "number", "description": "Seed CTL at the start date. Omit to derive it from the athlete's actual fitness."]
                    ],
                    "required": []
                ]
            ),
            ToolDefinition(
                name: "set_atp_event",
                description: "Add a race/event (omit event_id) or update an existing one (pass its event_id from get_atp). On update, only the fields you pass change. The engine re-periodizes around A/B events.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "event_id": ["type": "string", "description": "Omit to add a new event; pass an existing id (from get_atp) to update it."],
                        "name": ["type": "string", "description": "Event name."],
                        "date": ["type": "string", "description": "Event date (YYYY-MM-DD)."],
                        "event_type": ["type": "string", "enum": ATPEventType.allCases.map(\.rawValue),
                                       "description": "Discipline-scoped event type (e.g. marathon, tri_olympic, road_race)."],
                        "priority": ["type": "string", "enum": ["A", "B", "C"],
                                     "description": "A = goal race (anchors periodization + taper), B = secondary, C = training race (ignored by the engine). The engine doesn't validate A-race spacing — read_knowledge('trainingplan') before adding a second A event close to an existing one."],
                        "target_ctl": ["type": "number", "description": "Target fitness (CTL) on race day (target_ctl methodology)."],
                        "notes": ["type": "string", "description": "Optional free-text context for the coach."]
                    ],
                    "required": []
                ]
            ),
            ToolDefinition(
                name: "delete_atp_event",
                description: "Remove an event from the ATP by its id (from get_atp). The engine re-periodizes.",
                parameters: ["type": "object", "properties": ["event_id": eventIDProp], "required": ["event_id"]]
            ),
            ToolDefinition(
                name: "pin_atp_week",
                description: "Hold a specific week's TSS as a hard manual override the engine must honour (e.g. a known light week or a deliberate big block). tss 0 = a rest / vacation week. Overwrites any existing pin for that week.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "week": weekProp,
                        "tss": ["type": "number", "description": "The weekly TSS to lock in (0 = rest/vacation)."]
                    ],
                    "required": ["week", "tss"]
                ]
            ),
            ToolDefinition(
                name: "unpin_atp_week",
                description: "Remove a week's TSS pin so the engine solves that week freely again.",
                parameters: ["type": "object", "properties": ["week": weekProp], "required": ["week"]]
            )
        ]
    }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "get_atp": return Self.reportJSON(detailed: arguments["detail"] as? Bool ?? false)
        case "set_atp": return setConfig(arguments)
        case "set_atp_event": return setEvent(arguments)
        case "delete_atp_event": return deleteEvent(arguments)
        case "pin_atp_week": return pinWeek(arguments)
        case "unpin_atp_week": return unpinWeek(arguments)
        default: return "Unknown ATP tool: \(name)"
        }
    }

    // MARK: set_atp (config, merge-update)

    private func setConfig(_ args: [String: Any]) -> String {
        let existing = store.atpParams()

        let methodologyToken = Coerce.token(Coerce.string(args["methodology"]))
        if !methodologyToken.isEmpty && ATPMethodology(rawValue: methodologyToken) == nil {
            return "Invalid methodology — use weekly_tss or target_ctl."
        }
        guard let methodology = ATPMethodology(rawValue: methodologyToken) ?? existing?.methodology else {
            return "Set a methodology (weekly_tss or target_ctl) when first creating the ATP."
        }

        let weeklyAvg = Coerce.double(args["weekly_average_tss"]) ?? existing?.weeklyAverageTSS ?? 0
        if methodology == .weeklyTSS && weeklyAvg <= 0 {
            return "weekly_tss methodology needs a weekly_average_tss greater than 0."
        }
        var cycle = Coerce.int(args["recovery_cycle"]) ?? existing?.recoveryCycle ?? 4
        cycle = min(4, max(3, cycle))

        let params = ATPParams(
            startDate: Self.parseDay(Coerce.string(args["start_date"])) ?? existing?.startDate ?? Calendar.current.startOfDay(for: Date()),
            startingCTL: Coerce.double(args["starting_ctl"]) ?? existing?.startingCTL,
            methodology: methodology,
            recoveryCycle: cycle,
            maxRampRate: Coerce.double(args["max_ramp_rate"]) ?? existing?.maxRampRate ?? 7,
            weeklyAverageTSS: weeklyAvg)
        store.saveATPParams(params)
        return Self.reportJSON(message: "ATP config saved.")
    }

    // MARK: set_atp_event (upsert, merge-update)

    private func setEvent(_ args: [String: Any]) -> String {
        let id = Coerce.string(args["event_id"])
        let existing = id.flatMap { eid in store.atpEvents().first { $0.id == eid } }

        let typeToken = Coerce.token(Coerce.string(args["event_type"]))
        if !typeToken.isEmpty && ATPEventType(rawValue: typeToken) == nil {
            return "Invalid event_type. Valid values: \(ATPEventType.allCases.map(\.rawValue).joined(separator: ", "))."
        }
        let prioToken = (Coerce.string(args["priority"]) ?? "").uppercased()
        if !prioToken.isEmpty && ATPEventPriority(rawValue: prioToken) == nil {
            return "Invalid priority — use A, B or C."
        }

        let name = Coerce.string(args["name"]) ?? existing?.name
        let date = Self.parseDay(Coerce.string(args["date"])) ?? existing?.date
        let type = ATPEventType(rawValue: typeToken) ?? existing?.eventType
        let prio = ATPEventPriority(rawValue: prioToken) ?? existing?.priority
        guard let name, !name.isEmpty, let date, let type, let prio else {
            return "A new event needs name, date, event_type and priority."
        }

        let event = ATPEventInput(
            id: existing?.id ?? id ?? newEventID(),
            name: name, date: date, eventType: type, priority: prio,
            targetCTL: Coerce.double(args["target_ctl"]) ?? existing?.targetCTL,
            notes: Coerce.string(args["notes"]) ?? existing?.notes ?? "")
        store.upsertATPEvent(event)
        return Self.reportJSON(message: "\(existing == nil ? "Event added" : "Event updated") (id \(event.id)).")
    }

    /// A short, token-cheap event id (6 chars, a–z0–9), unique among current events.
    private func newEventID() -> String {
        let existing = Set(store.atpEvents().map(\.id))
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        while true {
            let id = String((0..<6).map { _ in chars.randomElement()! })
            if !existing.contains(id) { return id }
        }
    }

    private func deleteEvent(_ args: [String: Any]) -> String {
        guard let id = Coerce.string(args["event_id"]), !id.isEmpty else { return "Provide the event_id to delete." }
        guard store.atpEvents().contains(where: { $0.id == id }) else { return "No event with id \(id)." }
        store.deleteATPEvent(id: id)
        return Self.reportJSON(message: "Event deleted.")
    }

    // MARK: week pins

    private func pinWeek(_ args: [String: Any]) -> String {
        guard let week = Self.parseDay(Coerce.string(args["week"])) else { return "Provide a valid week date (YYYY-MM-DD)." }
        guard let tss = Coerce.double(args["tss"]), tss >= 0 else { return "Provide a non-negative tss to pin." }
        store.setATPOverride(weekStart: week, pinnedTSS: tss.rounded())
        return Self.reportJSON(message: "Week of \(Self.iso(TrainingVolume.weekStart(of: week))) pinned to \(Int(tss.rounded())) TSS.")
    }

    private func unpinWeek(_ args: [String: Any]) -> String {
        guard let week = Self.parseDay(Coerce.string(args["week"])) else { return "Provide a valid week date (YYYY-MM-DD)." }
        store.clearATPOverride(weekStart: week)
        return Self.reportJSON(message: "Week of \(Self.iso(TrainingVolume.weekStart(of: week))) unpinned.")
    }

    // MARK: Reports

    /// The compact ATP section injected into the system prompt each turn (prose, no ids —
    /// the coach calls get_atp for ids + detail).
    static func promptSection() -> String {
        guard let params = TrainingDataStore.shared.atpParams() else {
            return "=== ANNUAL TRAINING PLAN (ATP) ===\nNo ATP yet. Offer to build one: set_atp (methodology + volume) then set_atp_event for each race; the engine periodizes the weekly TSS and CTL."
        }
        guard let plan = ATPEngine.current() else {
            return "=== ANNUAL TRAINING PLAN (ATP) ===\nATP configured but not periodized — add at least one A/B race via set_atp_event."
        }
        return header(params: params, plan: plan, events: plan.events)
    }

    /// The full get_atp view as JSON, read straight from the store so events show their
    /// ids and pins are listed even before the plan periodizes. `message` carries a
    /// confirmation line back from the mutating tools.
    private static func reportJSON(message: String? = nil, detailed: Bool = false) -> String {
        let store = TrainingDataStore.shared
        let events = store.atpEvents().sorted { $0.date < $1.date }
        let pins = store.atpOverrides().sorted { $0.weekStart < $1.weekStart }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        var root: [String: Any] = [:]
        if let message { root["message"] = message }
        root["events"] = events.map(eventDict)
        if !pins.isEmpty {
            root["pinned_weeks"] = pins.map { p -> [String: Any] in
                ["week": iso(TrainingVolume.weekStart(of: p.weekStart)), "tss": Int(p.pinnedTSS), "rest": p.pinnedTSS == 0]
            }
        }

        guard let params = store.atpParams() else {
            root["configured"] = false
            return json(root)
        }
        root["configured"] = true
        root["methodology"] = params.methodology.rawValue
        root["recovery_cycle"] = params.recoveryCycle
        root["start_date"] = iso(params.startDate)
        if let ctl = params.startingCTL { root["starting_ctl"] = Int(ctl.rounded()) }
        switch params.methodology {
        case .weeklyTSS: root["weekly_average_tss"] = Int(params.weeklyAverageTSS)
        case .targetCTL: root["max_ramp_rate"] = Int(params.maxRampRate)
        }

        if let plan = ATPEngine.current() {
            if let cur = plan.weeks.first(where: { today >= $0.weekStart && today <= weekEnd($0.weekStart) }) {
                root["current"] = ["period": cur.period.label, "period_week": cur.periodWeekIndex, "week_target_tss": Int(cur.plannedTSS)]
            }
            if let a = events.first(where: { $0.priority == .a && $0.date >= today }) {
                let wks = max(0, cal.dateComponents([.weekOfYear], from: today, to: a.date).weekOfYear ?? 0)
                var d: [String: Any] = ["event_id": a.id, "name": a.name, "date": iso(a.date), "weeks_out": wks]
                if let t = a.targetCTL { d["target_ctl"] = Int(t) }
                if let proj = projectedCTL(plan, on: a.date) { d["projected_ctl"] = Int(proj) }
                root["next_a_race"] = d
            }
            let warn = plan.weeks.filter(\.rampExceeded).count
            if warn > 0 { root["ramp_warnings"] = warn }
            if detailed {
                let upcoming = plan.weeks.filter { $0.weekStart >= (cal.date(byAdding: .weekOfYear, value: -1, to: today) ?? today) }.prefix(8)
                root["upcoming_weeks"] = upcoming.map { w -> [String: Any] in
                    ["week": iso(w.weekStart), "period": w.period.label, "planned_tss": Int(w.plannedTSS),
                     "delta_ctl": (w.rampRate * 10).rounded() / 10, "pinned": w.pinned, "ramp_exceeded": w.rampExceeded]
                }
            }
        }
        return json(root)
    }

    private static func eventDict(_ e: ATPEventInput) -> [String: Any] {
        var d: [String: Any] = ["event_id": e.id, "name": e.name, "date": iso(e.date), "priority": e.priority.rawValue,
                                "discipline": e.eventType.discipline.rawValue, "event_type": e.eventType.rawValue]
        if let t = e.targetCTL { d["target_ctl"] = Int(t) }
        if !e.notes.isEmpty { d["notes"] = e.notes }
        return d
    }

    private static func json(_ obj: [String: Any]) -> String { String(compactJSON: obj) }

    // MARK: Formatting (system-prompt section)

    private static func header(params: ATPParams, plan: ATPPlan, events: [ATPEventInput]) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var lines = ["=== ANNUAL TRAINING PLAN (ATP) ==="]

        switch params.methodology {
        case .weeklyTSS: lines.append("Methodology: Weekly TSS (season average \(Int(params.weeklyAverageTSS)) TSS/wk).")
        case .targetCTL: lines.append("Methodology: Target CTL (max ramp \(Int(params.maxRampRate)) CTL/wk).")
        }
        lines.append("Recovery week every \(params.recoveryCycle) weeks.")

        if let cur = plan.weeks.first(where: { today >= $0.weekStart && today <= weekEnd($0.weekStart) }) {
            lines.append("Current period: \(cur.period.label) (week \(cur.periodWeekIndex)) — this week's target \(Int(cur.plannedTSS)) TSS.")
        }
        if let a = events.filter({ $0.priority == .a && $0.date >= today }).sorted(by: { $0.date < $1.date }).first {
            let days = max(0, cal.dateComponents([.day], from: today, to: a.date).day ?? 0)
            let countdown = days < 14
                ? "\(days) day\(days == 1 ? "" : "s") out"
                : "\(days / 7) wks out"
            var s = "Next A race: \(a.name) on \(iso(a.date)) (\(countdown))"
            if let t = a.targetCTL { s += ", target CTL \(Int(t))" }
            if let proj = projectedCTL(plan, on: a.date) { s += ", projected CTL \(Int(proj))" }
            lines.append(s + ".")
        }

        // Past events stay in the store (get_atp shows them) but don't spend
        // prompt tokens — only what's ahead matters for coaching decisions.
        let upcoming = events.filter { $0.date >= today }.sorted { $0.date < $1.date }
        if !upcoming.isEmpty {
            lines.append("Upcoming events:")
            for e in upcoming {
                var s = "• [\(e.priority.rawValue)] \(e.name) — \(e.eventType.discipline.label)/\(e.eventType.label) on \(iso(e.date))"
                if let t = e.targetCTL { s += " (target CTL \(Int(t)))" }
                lines.append("  " + s)
            }
        }
        let warn = plan.weeks.filter(\.rampExceeded).count
        if warn > 0 { lines.append("⚠️ \(warn) week(s) ramp faster than the max ramp rate (\(Int(params.maxRampRate)) CTL/wk).") }
        return lines.joined(separator: "\n")
    }

    /// True while the ATP's current week is a planned low-volume week (recovery,
    /// or peak/race/transition) — the training-load prompt section uses this to
    /// frame low week-to-date numbers as intentional.
    static func reducedVolumePlanned() -> Bool {
        guard let plan = ATPEngine.current() else { return false }
        let today = Calendar.current.startOfDay(for: Date())
        guard let cur = plan.weeks.first(where: { today >= $0.weekStart && today <= weekEnd($0.weekStart) }) else { return false }
        return cur.isRecovery || cur.isTaper || !cur.period.isBaseOrBuild
    }

    private static func weekEnd(_ weekStart: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
    }
    private static func projectedCTL(_ plan: ATPPlan, on date: Date) -> Double? {
        plan.planCurve.last(where: { $0.date <= weekEnd(TrainingVolume.weekStart(of: date)) })?.ctl
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
    private static func iso(_ date: Date) -> String { isoDay.string(from: date) }
    private static func parseDay(_ s: String?) -> Date? {
        guard let s, let d = isoDay.date(from: s) else { return nil }
        return Calendar.current.startOfDay(for: d)
    }
}
