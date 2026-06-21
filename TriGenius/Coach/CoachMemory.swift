import Foundation
import Combine

// MARK: - Coach Memory
//
// Persists athlete profile, preferences, training plan and feedback
// in a JSON file inside the app's Application Support directory.
// Mirrors the structure of the Python coach_memory.json.

/// Errors surfaced by `CoachMemory.importJSON`.
enum MemoryImportError: LocalizedError {
    case invalidFormat
    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "This file isn't a valid coach_memory.json."
        }
    }
}

final class CoachMemory: ObservableObject {

    // MARK: - Stored data

    @Published private(set) var userProfile: UserProfile
    @Published private(set) var weeklyStructure: WeeklyStructure
    @Published private(set) var preferences: AthletePreferences
    @Published private(set) var trainingPlan: TrainingPlan
    @Published private(set) var sportProgress: SportProgressMap
    @Published private(set) var feedbackHistory: [FeedbackEntry]
    @Published private(set) var onboardingComplete: Bool

    private let storageURL: URL

    // MARK: - Init

    init(filename: String = "coach_memory.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent(filename)

        // Start with defaults
        userProfile = UserProfile()
        weeklyStructure = WeeklyStructure()
        preferences = AthletePreferences()
        trainingPlan = TrainingPlan()
        sportProgress = SportProgressMap()
        feedbackHistory = []
        onboardingComplete = false

        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let p = raw["user_profile"] as? [String: Any] { userProfile = UserProfile(from: p) }
        if let w = raw["weekly_structure"] as? [String: Any] { weeklyStructure = WeeklyStructure(from: w) }
        if let pref = raw["preferences"] as? [String: Any] { preferences = AthletePreferences(from: pref) }
        if let tp = raw["training_plan"] as? [String: Any] { trainingPlan = TrainingPlan(from: tp) }
        if let sp = raw["sport_progress"] as? [String: Any] { sportProgress = SportProgressMap(from: sp) }
        if let fb = raw["feedback_history"] as? [[String: Any]] {
            feedbackHistory = fb.compactMap(FeedbackEntry.init(from:))
        }
        onboardingComplete = raw["onboarding_complete"] as? Bool ?? false
    }

    /// Replace the entire in-memory state from a `coach_memory.json` payload — the
    /// same shape `save()` writes and the debug view shows — and persist it.
    /// Sections missing from the file reset to their defaults: this is a full
    /// restore, not a merge. Performance scalars (FTP, CSS, …) carried by an
    /// exported/legacy profile stay on the in-memory `userProfile` so the caller
    /// can seed them into the metric time series (`UserProfile.toDict()` no longer
    /// persists them — see its comment).
    func importJSON(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let raw = object as? [String: Any] else { throw MemoryImportError.invalidFormat }

        userProfile = (raw["user_profile"] as? [String: Any]).map { UserProfile(from: $0) } ?? UserProfile()
        weeklyStructure = (raw["weekly_structure"] as? [String: Any]).map { WeeklyStructure(from: $0) } ?? WeeklyStructure()
        preferences = (raw["preferences"] as? [String: Any]).map { AthletePreferences(from: $0) } ?? AthletePreferences()
        trainingPlan = (raw["training_plan"] as? [String: Any]).map { TrainingPlan(from: $0) } ?? TrainingPlan()
        sportProgress = (raw["sport_progress"] as? [String: Any]).map { SportProgressMap(from: $0) } ?? SportProgressMap()
        feedbackHistory = (raw["feedback_history"] as? [[String: Any]] ?? []).compactMap(FeedbackEntry.init(from:))
        onboardingComplete = raw["onboarding_complete"] as? Bool ?? false
        save()
    }

    func save() {
        let dict: [String: Any] = [
            "user_profile": userProfile.toDict(),
            "weekly_structure": weeklyStructure.toDict(),
            "preferences": preferences.toDict(),
            "training_plan": trainingPlan.toDict(),
            "sport_progress": sportProgress.toDict(),
            "feedback_history": feedbackHistory.map { $0.toDict() },
            "onboarding_complete": onboardingComplete
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) else { return }
        // Write off the main thread; serialization already captured the data.
        let url = storageURL
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Debug helpers

    /// Absolute path to the JSON file on disk.
    var storageFilePath: String { storageURL.path }

    /// The current in-memory state serialized as pretty-printed JSON.
    /// Falls back to the on-disk file if serialization fails.
    var prettyPrintedJSON: String {
        let dict: [String: Any] = [
            "user_profile": userProfile.toDict(),
            "weekly_structure": weeklyStructure.toDict(),
            "preferences": preferences.toDict(),
            "training_plan": trainingPlan.toDict(),
            "sport_progress": sportProgress.toDict(),
            "feedback_history": feedbackHistory.map { $0.toDict() },
            "onboarding_complete": onboardingComplete
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return (try? String(contentsOf: storageURL, encoding: .utf8)) ?? "{}"
    }

    // MARK: - Mutation helpers

    func updateProfile(_ update: (inout UserProfile) -> Void) {
        update(&userProfile)
        save()
    }

    func updateWeeklyStructure(_ update: (inout WeeklyStructure) -> Void) {
        update(&weeklyStructure)
        save()
    }

    func updatePreferences(_ update: (inout AthletePreferences) -> Void) {
        update(&preferences)
        save()
    }

    func updateTrainingPlan(_ update: (inout TrainingPlan) -> Void) {
        update(&trainingPlan)
        save()
    }

    func updateSportProgress(sport: String, _ update: (inout SportProgress) -> Void) {
        var sp = sportProgress.progress(for: sport)
        update(&sp)
        sportProgress.setProgress(sp, for: sport)
        save()
    }

    func addFeedback(_ text: String, category: String = "general") {
        let entry = FeedbackEntry(date: Date(), category: category, feedback: text)
        feedbackHistory.append(entry)
        if feedbackHistory.count > 50 { feedbackHistory.removeFirst() }
        save()
    }

    func markOnboardingComplete() {
        onboardingComplete = true
        save()
    }

    // MARK: - Context summary for LLM

    /// Performance metrics (FTP, CSS, …) are auto-synced from the data source and
    /// are deliberately NOT requested here — the coach neither asks for nor edits
    /// them. Only profile facts the athlete must supply are listed.
    func missingInfo(performance: PerformanceSnapshot) -> [String] {
        var items: [String] = []
        if userProfile.name == nil { items.append("athlete name") }
        if performance.maxHR == nil { items.append("maximum heart rate") }
        if userProfile.goals.isEmpty { items.append("training goals (e.g. triathlon, marathon)") }
        if weeklyStructure.maxHours == nil { items.append("maximum training hours per week") }
        return items
    }

    /// `performance` is the latest-per-metric snapshot read from the DB
    /// (`TrainingDataStore.latestSnapshot()`), the source of truth for FTP/CSS/etc.
    func contextSummary(performance: PerformanceSnapshot) -> String {
        var parts = ["=== ATHLETE CONTEXT ==="]

        let missing = missingInfo(performance: performance)
        if !missing.isEmpty {
            parts.append("\n⚠️ MISSING INFORMATION (please ask the athlete):")
            missing.forEach { parts.append("  - \($0)") }
        }

        parts.append("\n--- Known information ---")
        if let name = userProfile.name { parts.append("Name: \(name)") }
        if let ftp = performance.cyclingFTP { parts.append("FTP: \(ftp) W") }
        if let runFTP = performance.runningFTP { parts.append("Running threshold power: \(runFTP) W") }
        if let maxHR = performance.maxHR { parts.append("Max HR: \(maxHR) bpm") }
        if let lthr = performance.lactateThrHR { parts.append("Lactate threshold HR: \(lthr) bpm") }
        if let ltPace = performance.lactateThrPaceFormatted { parts.append("Lactate threshold pace: \(ltPace)/km") }
        if let css = performance.cssPaceFormatted { parts.append("CSS: \(css)/100m") }
        if let vo2 = performance.vo2maxRunning { parts.append("VO2max (running): \(vo2)") }
        if let vo2c = performance.vo2maxCycling { parts.append("VO2max (cycling): \(vo2c)") }
        if !userProfile.goals.isEmpty { parts.append("Goals: \(userProfile.goals.joined(separator: ", "))") }
        if let maxH = weeklyStructure.maxHours { parts.append("Max weekly hours: \(maxH)") }
        if let rd = weeklyStructure.preferredRestDay { parts.append("Rest day: \(rd)") }

        // Training plan
        let plan = trainingPlan
        if plan.targetEvent != nil || plan.currentPhase != nil || !plan.phases.isEmpty {
            parts.append("\n=== TRAINING PLAN ===")
            if let ev = plan.targetEvent {
                var s = "Target event: \(ev)"
                if let d = plan.eventDate { s += " (\(d))" }
                parts.append(s)
            }
            if !plan.phases.isEmpty {
                if let week = plan.currentWeek(), let total = plan.totalWeeks {
                    parts.append("Plan progress: week \(week) of \(total)")
                }
                if let current = plan.phase() {
                    parts.append("Current phase: \(current.name.rawValue.uppercased()) (\(current.startDate) to \(current.endDate))")
                }
                parts.append("Phases:")
                for p in plan.phases {
                    var line = "  • \(p.name.rawValue) [\(p.startDate) → \(p.endDate)]"
                    if let f = p.focus, !f.isEmpty { line += " — \(f)" }
                    let targets = ["swimming", "cycling", "running", "strength"].compactMap { sport -> String? in
                        guard let t = p.sportTargets[sport], t.hasData else { return nil }
                        var tp: [String] = []
                        if let km = t.weeklyDistanceKm { tp.append("\(Int(km.rounded()))km") }
                        if let tss = t.weeklyTSS { tp.append("\(tss)TSS") }
                        return "\(sport): \(tp.joined(separator: "/"))"
                    }
                    if !targets.isEmpty { line += " | targets/wk: \(targets.joined(separator: ", "))" }
                    parts.append(line)
                }
            } else if let phase = plan.currentPhase {
                var s = "Current phase: \(phase.uppercased())"
                if let s1 = plan.phaseStartDate, let e1 = plan.phaseEndDate { s += " (\(s1) to \(e1))" }
                parts.append(s)
            }
            if let focus = plan.monthlyFocus { parts.append("Focus this month: \(focus)") }
        }

        // Sport progress
        let sports = ["swimming", "cycling", "running", "strength"]
        for sport in sports {
            let sp = sportProgress.progress(for: sport)
            guard sp.hasData else { continue }
            parts.append("\n[\(sport.uppercased())]")
            if let lvl = sp.currentLevel { parts.append("  Level: \(lvl)") }
            if !sp.abilities.isEmpty { parts.append("  ✓ Can do: \(sp.abilities.joined(separator: ", "))") }
            if !sp.limitations.isEmpty {
                let lims = sp.limitations.map { l -> String in
                    var s = l.item
                    if let r = l.reason { s += " (\(r))" }
                    return s
                }
                parts.append("  ✗ Cannot do/Avoid: \(lims.joined(separator: ", "))")
            }
            if !sp.injuriesAffecting.isEmpty {
                let injs = sp.injuriesAffecting.map { "\($0.injury): \($0.impact)" }
                parts.append("  ⚠️ Injuries: \(injs.joined(separator: "; "))")
            }
            if let focus = sp.currentFocus { parts.append("  Focus: \(focus)") }
            if !sp.equipment.isEmpty { parts.append("  Equipment: \(sp.equipment.joined(separator: ", "))") }
        }

        // Recent feedback
        let recent = feedbackHistory.suffix(5)
        if !recent.isEmpty {
            parts.append("\nLatest feedback:")
            recent.forEach { parts.append("  - [\($0.category)] \($0.feedback)") }
        }

        return parts.joined(separator: "\n")
    }
}

// MARK: - Sub-models

struct UserProfile {
    var name: String?
    var goals: [String] = []
    var coordinates: (lat: Double, lon: Double)?

    // Legacy performance/biometric values. Performance metrics (FTP, CSS, VO2max,
    // lactate-threshold HR, max HR, weight and HR/power zones) now live in the
    // SwiftData time series (`PerformanceMetricRecord`); these are parsed from an
    // existing `coach_memory.json` only so the one-time seed can migrate them into
    // the DB, and are no longer written back (see `toDict()`).
    var ftp: Int?
    var cssPace: String?
    var vo2max: Double?
    var lactateThrHR: Int?
    var maxHR: Int?
    var weightKg: Double?
    var zones: [String: Any] = [:]

    init() {}

    init(from d: [String: Any]) {
        name = d["name"] as? String
        ftp = d["ftp"] as? Int
        maxHR = d["max_hr"] as? Int
        cssPace = d["css_pace_per_100m"] as? String
        goals = d["goals"] as? [String] ?? []
        vo2max = d["vo2max"] as? Double
        weightKg = d["weight_kg"] as? Double
        lactateThrHR = d["lactate_threshold_hr"] as? Int
        zones = d["zones"] as? [String: Any] ?? [:]
        if let coords = d["coordinates"] as? [String: Any],
           let lat = coords["lat"] as? Double,
           let lon = coords["lon"] as? Double {
            coordinates = (lat, lon)
        }
    }

    func toDict() -> [String: Any] {
        // Performance/biometric values (ftp, css, vo2max, lactate_threshold_hr,
        // max_hr, weight_kg, zones) intentionally omitted — they now live in the
        // performance-metric time series (`PerformanceMetricRecord`).
        var d: [String: Any] = [
            "goals": goals
        ]
        if let v = name { d["name"] = v }
        if let c = coordinates { d["coordinates"] = ["lat": c.lat, "lon": c.lon] }
        return d
    }
}

struct WeeklyStructure {
    var maxHours: Int?
    var preferredRestDay: String?
    var longRunDay: String?
    var longRideDay: String?

    init() {}

    init(from d: [String: Any]) {
        maxHours = d["max_hours"] as? Int
        preferredRestDay = d["preferred_rest_day"] as? String
        longRunDay = d["long_run_day"] as? String
        longRideDay = d["long_ride_day"] as? String
    }

    func toDict() -> [String: Any] {
        var d: [String: Any] = [:]
        if let v = maxHours { d["max_hours"] = v }
        if let v = preferredRestDay { d["preferred_rest_day"] = v }
        if let v = longRunDay { d["long_run_day"] = v }
        if let v = longRideDay { d["long_ride_day"] = v }
        return d
    }
}

struct AthletePreferences {
    var noSwimDays: [String] = []
    var noBikeDays: [String] = []
    var noRunDays: [String] = []
    var morningWorkouts: Bool?
    var indoorTrainerAvailable: Bool?

    init() {}

    init(from d: [String: Any]) {
        noSwimDays = d["no_swim_days"] as? [String] ?? []
        noBikeDays = d["no_bike_days"] as? [String] ?? []
        noRunDays = d["no_run_days"] as? [String] ?? []
        morningWorkouts = d["morning_workouts"] as? Bool
        indoorTrainerAvailable = d["indoor_trainer_available"] as? Bool
    }

    func toDict() -> [String: Any] {
        var d: [String: Any] = [
            "no_swim_days": noSwimDays,
            "no_bike_days": noBikeDays,
            "no_run_days": noRunDays
        ]
        if let v = morningWorkouts { d["morning_workouts"] = v }
        if let v = indoorTrainerAvailable { d["indoor_trainer_available"] = v }
        return d
    }
}

/// Standard triathlon periodization phases. A fixed set — the coach and UI pick
/// from these exact values rather than fuzzy-matching free text.
enum PhaseName: String, CaseIterable, Identifiable {
    case prep       = "Prep"
    case base       = "Base"
    case build      = "Build"
    case peak       = "Peak"
    case taper      = "Taper"
    case race       = "Race"
    case recovery   = "Recovery"
    case transition = "Transition"

    var id: String { rawValue }

    /// Exact (case-insensitive) match only — no fuzzy/substring matching.
    init?(stored raw: String) {
        let needle = raw.lowercased()
        guard let match = PhaseName.allCases.first(where: { $0.rawValue.lowercased() == needle }) else { return nil }
        self = match
    }
}

/// A per-discipline weekly target inside a phase. Either expressed as a weekly
/// distance, a weekly TSS load, or both — whatever the athlete/coach sets.
struct SportTarget {
    var weeklyDistanceKm: Double?
    var weeklyTSS: Int?

    var hasData: Bool { weeklyDistanceKm != nil || weeklyTSS != nil }

    init(weeklyDistanceKm: Double? = nil, weeklyTSS: Int? = nil) {
        self.weeklyDistanceKm = weeklyDistanceKm
        self.weeklyTSS = weeklyTSS
    }

    init(from d: [String: Any]) {
        weeklyDistanceKm = (d["weekly_distance_km"] as? NSNumber)?.doubleValue
        weeklyTSS = (d["weekly_tss"] as? NSNumber)?.intValue
    }

    func toDict() -> [String: Any] {
        var d: [String: Any] = [:]
        if let v = weeklyDistanceKm { d["weekly_distance_km"] = v }
        if let v = weeklyTSS { d["weekly_tss"] = v }
        return d
    }
}

/// One block of the training plan: a named phase with a date range, a focus
/// line, and per-sport weekly targets (keyed by sport: swimming/cycling/running/strength).
struct Phase: Identifiable {
    var id = UUID()
    var name: PhaseName
    var startDate: String   // ISO "yyyy-MM-dd"
    var endDate: String     // ISO "yyyy-MM-dd"
    var focus: String?
    var sportTargets: [String: SportTarget] = [:]

    init(name: PhaseName, startDate: String, endDate: String, focus: String? = nil,
         sportTargets: [String: SportTarget] = [:]) {
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.focus = focus
        self.sportTargets = sportTargets
    }

    init?(from d: [String: Any]) {
        guard let rawName = d["name"] as? String, let phase = PhaseName(stored: rawName),
              let start = d["start_date"] as? String, let end = d["end_date"] as? String else { return nil }
        name = phase
        startDate = start
        endDate = end
        focus = d["focus"] as? String
        if let targets = d["sport_targets"] as? [String: Any] {
            for (sport, val) in targets {
                if let t = val as? [String: Any] { sportTargets[sport.lowercased()] = SportTarget(from: t) }
            }
        }
    }

    func toDict() -> [String: Any] {
        var d: [String: Any] = [
            "name": name.rawValue,
            "start_date": startDate,
            "end_date": endDate
        ]
        if let v = focus { d["focus"] = v }
        if !sportTargets.isEmpty {
            d["sport_targets"] = sportTargets.mapValues { $0.toDict() }
        }
        return d
    }

    func start() -> Date? { TrainingPlan.isoDate(startDate) }
    func end() -> Date? { TrainingPlan.isoDate(endDate) }
}

struct TrainingPlan {
    var targetEvent: String?
    var eventDate: String?
    var currentPhase: String?
    var phaseStartDate: String?
    var phaseEndDate: String?
    var monthlyFocus: String?
    var notes: String?
    var phases: [Phase] = []

    init() {}

    init(from d: [String: Any]) {
        targetEvent = d["target_event"] as? String
        eventDate = d["event_date"] as? String
        currentPhase = d["current_phase"] as? String
        phaseStartDate = d["phase_start_date"] as? String
        phaseEndDate = d["phase_end_date"] as? String
        monthlyFocus = d["monthly_focus"] as? String
        notes = d["notes"] as? String
        if let raw = d["phases"] as? [[String: Any]] {
            phases = raw.compactMap { Phase(from: $0) }.sorted { ($0.start() ?? .distantPast) < ($1.start() ?? .distantPast) }
        }
    }

    func toDict() -> [String: Any] {
        var d: [String: Any] = [:]
        if let v = targetEvent { d["target_event"] = v }
        if let v = eventDate { d["event_date"] = v }
        if let v = currentPhase { d["current_phase"] = v }
        if let v = phaseStartDate { d["phase_start_date"] = v }
        if let v = phaseEndDate { d["phase_end_date"] = v }
        if let v = monthlyFocus { d["monthly_focus"] = v }
        if let v = notes { d["notes"] = v }
        if !phases.isEmpty { d["phases"] = phases.map { $0.toDict() } }
        return d
    }

    // MARK: - Derived plan geometry

    static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func isoDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return isoFormatter.date(from: s)
    }

    var eventDay: Date? { TrainingPlan.isoDate(eventDate) }

    /// The phase covering `date` (inclusive of both ends).
    func phase(on date: Date = Date()) -> Phase? {
        let day = Calendar.current.startOfDay(for: date)
        return phases.first { p in
            guard let s = p.start(), let e = p.end() else { return false }
            return day >= Calendar.current.startOfDay(for: s) && day <= Calendar.current.startOfDay(for: e)
        }
    }

    /// First phase start (plan beginning).
    var planStart: Date? { phases.compactMap { $0.start() }.min() }

    /// Plan end — the event day if set, else the last phase end.
    var planEnd: Date? {
        eventDay ?? phases.compactMap { $0.end() }.max()
    }

    /// Total number of calendar weeks the plan spans (≥ 1 when dated).
    var totalWeeks: Int? {
        guard let start = planStart, let end = planEnd, end > start else { return nil }
        let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
        return max(1, Int(ceil(Double(days) / 7.0)))
    }

    /// 1-based index of the current week within the plan, clamped to the plan span.
    func currentWeek(on date: Date = Date()) -> Int? {
        guard let start = planStart, let total = totalWeeks else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: start),
                                                   to: Calendar.current.startOfDay(for: date)).day ?? 0
        return min(max(1, days / 7 + 1), total)
    }

    /// Whole days from `date` until the event (negative once it has passed).
    func daysUntilEvent(from date: Date = Date()) -> Int? {
        guard let event = eventDay else { return nil }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date),
                                               to: Calendar.current.startOfDay(for: event)).day
    }
}

struct SportProgressMap {
    private var map: [String: SportProgress] = [:]

    init() {}

    init(from d: [String: Any]) {
        for (key, val) in d {
            if let sp = val as? [String: Any] {
                map[key] = SportProgress(from: sp)
            }
        }
    }

    func progress(for sport: String) -> SportProgress {
        map[sport.lowercased()] ?? SportProgress()
    }

    mutating func setProgress(_ p: SportProgress, for sport: String) {
        map[sport.lowercased()] = p
    }

    func toDict() -> [String: Any] {
        map.mapValues { $0.toDict() }
    }
}

struct SportProgress {
    var currentLevel: String?
    var abilities: [String] = []
    var limitations: [Limitation] = []
    var injuriesAffecting: [InjuryImpact] = []
    var currentFocus: String?
    var maxContinuous: String?
    var equipment: [String] = []
    var notes: String?

    var hasData: Bool {
        currentLevel != nil || !abilities.isEmpty || !limitations.isEmpty ||
        !injuriesAffecting.isEmpty || currentFocus != nil || !equipment.isEmpty
    }

    init() {}

    init(from d: [String: Any]) {
        currentLevel = d["current_level"] as? String
        abilities = d["abilities"] as? [String] ?? []
        limitations = (d["limitations"] as? [[String: Any]] ?? []).compactMap(Limitation.init(from:))
        injuriesAffecting = (d["injuries_affecting"] as? [[String: Any]] ?? []).compactMap(InjuryImpact.init(from:))
        currentFocus = d["current_focus"] as? String
        maxContinuous = d["max_continuous"] as? String
        equipment = d["equipment"] as? [String] ?? []
        notes = d["notes"] as? String
    }

    func toDict() -> [String: Any] {
        var d: [String: Any] = [
            "abilities": abilities,
            "limitations": limitations.map { $0.toDict() },
            "injuries_affecting": injuriesAffecting.map { $0.toDict() },
            "equipment": equipment
        ]
        if let v = currentLevel { d["current_level"] = v }
        if let v = currentFocus { d["current_focus"] = v }
        if let v = maxContinuous { d["max_continuous"] = v }
        if let v = notes { d["notes"] = v }
        return d
    }
}

nonisolated struct Limitation {
    let item: String
    let reason: String?

    init?(from d: [String: Any]) {
        guard let item = d["item"] as? String else { return nil }
        self.item = item
        reason = d["reason"] as? String
    }

    func toDict() -> [String: Any] {
        var d: [String: Any] = ["item": item]
        if let r = reason { d["reason"] = r }
        return d
    }
}

nonisolated struct InjuryImpact {
    let injury: String
    let impact: String

    init?(from d: [String: Any]) {
        guard let i = d["injury"] as? String, let imp = d["impact"] as? String else { return nil }
        injury = i; impact = imp
    }

    func toDict() -> [String: Any] { ["injury": injury, "impact": impact] }
}

nonisolated struct FeedbackEntry {
    let date: Date
    let category: String
    let feedback: String

    init(date: Date, category: String, feedback: String) {
        self.date = date; self.category = category; self.feedback = feedback
    }

    init?(from d: [String: Any]) {
        guard let fb = d["feedback"] as? String else { return nil }
        feedback = fb
        category = d["category"] as? String ?? "general"
        if let dateStr = d["date"] as? String,
           let d = ISO8601DateFormatter().date(from: dateStr) {
            date = d
        } else {
            date = Date()
        }
    }

    func toDict() -> [String: Any] {
        [
            "date": ISO8601DateFormatter().string(from: date),
            "category": category,
            "feedback": feedback
        ]
    }
}
