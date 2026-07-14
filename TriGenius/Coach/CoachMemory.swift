import Foundation
import Combine

// MARK: - Coach Memory
//
// The athlete profile, preferences, weekly structure, sport progress and feedback
// the coach reasons over. Backed by SwiftData rows (`CoachMemoryModels.swift`) so it
// rides the one CloudKit sync; this class is the `@MainActor` façade that assembles
// those rows into the value structs the app consumes and writes mutations back.
// Snake_case keys (`init(from:)` / `toDict()`) match the legacy coach_memory.json,
// which the launch migration imports once and which import/export still round-trips.

/// Errors surfaced by `CoachMemory.importJSON`.
enum MemoryImportError: LocalizedError {
    case invalidFormat
    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "This file isn't a valid coach_memory.json."
        }
    }
}

@MainActor
final class CoachMemory: ObservableObject {

    // MARK: - Stored data

    @Published private(set) var userProfile: UserProfile
    @Published private(set) var weeklyStructure: WeeklyStructure
    @Published private(set) var preferences: AthletePreferences
    @Published private(set) var sportProgress: SportProgressMap
    @Published private(set) var feedbackHistory: [FeedbackEntry]

    // MARK: - Init

    /// Assembled from the SwiftData coach-memory rows. `CoachMemory` is the sole
    /// writer of those rows, so the in-memory copy is authoritative.
    init() {
        let store = TrainingDataStore.shared
        userProfile = store.coachProfile()
        weeklyStructure = store.coachWeeklyStructure()
        preferences = store.coachPreferences()
        sportProgress = store.coachSportProgress()
        feedbackHistory = store.coachFeedback()
    }

    // MARK: - Persistence

    /// Write the whole in-memory state back to the store as a full replace — used by
    /// `importJSON`'s restore. The per-section mutators below persist incrementally.
    private func persistAll() {
        TrainingDataStore.shared.replaceCoachMemory(
            profile: userProfile,
            weeklyStructure: weeklyStructure, preferences: preferences,
            sportProgress: sportProgress, feedback: feedbackHistory)
    }

    /// Erase all coach memory to a fresh state — part of the in-app "Delete all my
    /// data". Clears the in-memory copy and the backing rows (which propagates to
    /// the CloudKit mirror).
    func reset() {
        userProfile = UserProfile()
        weeklyStructure = WeeklyStructure()
        preferences = AthletePreferences()
        sportProgress = SportProgressMap()
        feedbackHistory = []
        persistAll()
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
        sportProgress = (raw["sport_progress"] as? [String: Any]).map { SportProgressMap(from: $0) } ?? SportProgressMap()
        feedbackHistory = (raw["feedback_history"] as? [[String: Any]] ?? []).compactMap(FeedbackEntry.init(from:))
        persistAll()
    }

    // MARK: - Debug helpers

    /// Path of the SwiftData store now backing coach memory (debug display).
    var storageFilePath: String { TrainingDataStore.shared.storeFilePath }

    /// The pre-migration coach_memory.json location, read once by the launch
    /// migration into the store rows.
    static var legacyFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("coach_memory.json")
    }

    /// The current in-memory state serialized as pretty-printed JSON.
    /// Falls back to the on-disk file if serialization fails.
    var prettyPrintedJSON: String {
        let dict: [String: Any] = [
            "user_profile": userProfile.toDict(),
            "weekly_structure": weeklyStructure.toDict(),
            "preferences": preferences.toDict(),
            "sport_progress": sportProgress.toDict(),
            "feedback_history": feedbackHistory.map { $0.toDict() }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    // MARK: - Mutation helpers

    func updateProfile(_ update: (inout UserProfile) -> Void) {
        update(&userProfile)
        TrainingDataStore.shared.saveCoachProfile(userProfile)
    }

    func updateWeeklyStructure(_ update: (inout WeeklyStructure) -> Void) {
        update(&weeklyStructure)
        TrainingDataStore.shared.saveCoachWeeklyStructure(weeklyStructure)
    }

    func updatePreferences(_ update: (inout AthletePreferences) -> Void) {
        update(&preferences)
        TrainingDataStore.shared.saveCoachPreferences(preferences)
    }

    func updateSportProgress(sport: String, _ update: (inout SportProgress) -> Void) {
        var sp = sportProgress.progress(for: sport)
        update(&sp)
        sportProgress.setProgress(sp, for: sport)
        TrainingDataStore.shared.saveCoachSportProgress(sp, for: sport)
    }

    func addFeedback(_ text: String, category: String = "general") {
        let entry = FeedbackEntry(date: Date(), category: category, feedback: text)
        feedbackHistory.append(entry)
        if feedbackHistory.count > 50 { feedbackHistory.removeFirst() }
        TrainingDataStore.shared.appendCoachFeedback(entry, cap: 50)
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

    /// Feedback older than this leaves the prompt (the rows stay in the DB) —
    /// the MEMORY prompt section tells the coach to promote anything durable to
    /// the profile before it ages out.
    static let feedbackWindowWeeks = 8

    /// `history` is the full performance-metric time series
    /// (`TrainingDataStore.performanceHistory()`): the latest values plus the
    /// as-of-3-months-ago snapshot behind each marker's "was" annotation. Markers
    /// are step functions (a value holds until replaced), so every "was" value is
    /// a real stored reading — nothing is interpolated.
    func contextSummary(history: PerformanceHistory) -> String {
        let now = history.snapshot(asOf: .distantFuture)
        let prev = history.snapshot(
            asOf: Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
        )
        var parts = ["=== ATHLETE ==="]

        parts.append("[xxxx] tags on entries below are internal removal ids for the update tools — never show or mention them to the athlete.")

        let missing = missingInfo(performance: now)
        if !missing.isEmpty {
            parts.append("\n⚠️ MISSING INFORMATION (please ask the athlete):")
            missing.forEach { parts.append("  - \($0)") }
        }

        var identity: [String] = []
        if let name = userProfile.name { identity.append(name) }
        if let maxH = weeklyStructure.maxHours { identity.append("max \(maxH) h/wk") }
        if let rd = weeklyStructure.preferredRestDay { identity.append("rest day \(rd)") }
        if !identity.isEmpty { parts.append(identity.joined(separator: " · ")) }
        if !userProfile.goals.isEmpty {
            var goals = "Goals: \(userProfile.goals.map { "[\(MemoryRef.id($0))] \($0)" }.joined(separator: ", "))"
            if let m = userProfile.motivation { goals += " — motivation: \(m)" }
            parts.append(goals)
        }

        // Physiological markers, each annotated with its 3-months-ago value when
        // it changed. Garmin running power is deliberately not rendered (its watt
        // scale isn't comparable to cycling and invites bad comparisons).
        var markers: [String] = []
        func marker(_ label: String, _ cur: String?, _ was: String?) {
            guard let cur else { return }
            markers.append(was != nil && was != cur ? "\(label) \(cur) (was \(was!))" : "\(label) \(cur)")
        }
        marker("FTP", now.cyclingFTP.map { "\($0) W" }, prev.cyclingFTP.map { "\($0) W" })
        marker("max HR", now.maxHR.map { "\($0) bpm" }, prev.maxHR.map { "\($0) bpm" })
        marker("LTHR", now.lactateThrHR.map { "\($0) bpm" }, prev.lactateThrHR.map { "\($0) bpm" })
        marker("LT pace", now.lactateThrPaceFormatted.map { "\($0)/km" }, prev.lactateThrPaceFormatted.map { "\($0)/km" })
        marker("CSS", now.cssPaceFormatted.map { "\($0)/100m" }, prev.cssPaceFormatted.map { "\($0)/100m" })
        marker("VO2max run", now.vo2maxRunning.map { String(format: "%.0f", $0) }, prev.vo2maxRunning.map { String(format: "%.0f", $0) })
        marker("VO2max bike", now.vo2maxCycling.map { String(format: "%.0f", $0) }, prev.vo2maxCycling.map { String(format: "%.0f", $0) })
        if !markers.isEmpty {
            parts.append("Markers (current; \"was\" = 3 months ago): " + markers.joined(separator: " · "))
        }

        let sports = ["swimming", "cycling", "running", "strength"]

        // Hard limits: stated limitations + active injuries — the binding set.
        var limits: [String] = []
        for sport in sports {
            let sp = sportProgress.progress(for: sport)
            for l in sp.limitations {
                limits.append("[\(l.refId)] \(sport): \(l.item)" + (l.reason.map { " (\($0))" } ?? ""))
            }
            for i in sp.injuriesAffecting {
                limits.append("[\(i.refId)] \(sport) injury: \(i.injury) — \(i.impact)")
            }
        }
        if !limits.isEmpty {
            parts.append("\nHARD LIMITS (binding — never prescribe against these):")
            limits.forEach { parts.append("- \($0)") }
        }

        // Preferences: guidance the coach honors by default, not hard rules.
        if !preferences.trainingPreferences.isEmpty {
            parts.append("\nPREFERENCES (honor by default; the athlete may override):")
            preferences.trainingPreferences.forEach { parts.append("- [\(MemoryRef.id($0))] \($0)") }
        }

        // Per-sport notes: level / abilities / focus / equipment, one line each.
        var sportLines: [String] = []
        for sport in sports {
            let sp = sportProgress.progress(for: sport)
            var bits: [String] = []
            if let lvl = sp.currentLevel { bits.append("level \(lvl)") }
            if !sp.abilities.isEmpty { bits.append("can do: \(sp.abilities.joined(separator: ", "))") }
            if let focus = sp.currentFocus { bits.append("focus: \(focus)") }
            if !sp.equipment.isEmpty { bits.append("equipment: \(sp.equipment.joined(separator: ", "))") }
            if !bits.isEmpty { sportLines.append("- \(sport): \(bits.joined(separator: "; "))") }
        }
        if !sportLines.isEmpty {
            parts.append("\nSPORT NOTES:")
            parts.append(contentsOf: sportLines)
        }

        // Recent feedback, dated, newest first, windowed.
        let cutoff = Calendar.current.date(byAdding: .weekOfYear, value: -Self.feedbackWindowWeeks, to: Date()) ?? Date()
        let recent = feedbackHistory.filter { $0.date >= cutoff }.suffix(10).reversed()
        if !recent.isEmpty {
            parts.append("\nRECENT FEEDBACK (last \(Self.feedbackWindowWeeks) weeks, newest first):")
            recent.forEach { parts.append("- \(DateFormatter.ymd.string(from: $0.date)) [\($0.category)] \($0.feedback)") }
        }

        return parts.joined(separator: "\n")
    }
}

// MARK: - Sub-models

struct UserProfile {
    var name: String?
    var goals: [String] = []
    /// The "why" behind the goals — changes coaching trade-offs, not just tone.
    var motivation: String?
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
        motivation = d["motivation"] as? String
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
        if let v = motivation { d["motivation"] = v }
        if let c = coordinates { d["coordinates"] = ["lat": c.lat, "lon": c.lon] }
        return d
    }
}

struct WeeklyStructure {
    var maxHours: Int?
    var preferredRestDay: String?
    var longRunDay: String?
    var longRideDay: String?
    /// Per-discipline weekly-TSS weights for the ATP sport split (approach A) — the
    /// only sport-aware input to the otherwise sport-agnostic ATP. Defaults to the
    /// classic 20/50/30 swim/bike/run; keys are `SportFamily` raw values.
    var sportRatio: [SportFamily: Double] = WeeklyStructure.defaultSportRatio
    /// Optional per-discipline minimum weekly TSS (e.g. a swim floor for a bike-heavy
    /// athlete who'd otherwise neglect it). Empty by default.
    var sportFloors: [SportFamily: Double] = [:]

    static let defaultSportRatio: [SportFamily: Double] = [.swim: 0.20, .bike: 0.50, .run: 0.30]

    init() {}

    init(from d: [String: Any]) {
        maxHours = d["max_hours"] as? Int
        preferredRestDay = d["preferred_rest_day"] as? String
        longRunDay = d["long_run_day"] as? String
        longRideDay = d["long_ride_day"] as? String
        if let r = d["sport_ratio"] as? [String: Any] { sportRatio = WeeklyStructure.familyMap(r) }
        if let f = d["sport_floors"] as? [String: Any] { sportFloors = WeeklyStructure.familyMap(f) }
    }

    func toDict() -> [String: Any] {
        var d: [String: Any] = [:]
        if let v = maxHours { d["max_hours"] = v }
        if let v = preferredRestDay { d["preferred_rest_day"] = v }
        if let v = longRunDay { d["long_run_day"] = v }
        if let v = longRideDay { d["long_ride_day"] = v }
        if !sportRatio.isEmpty { d["sport_ratio"] = stringKeyed(sportRatio) }
        if !sportFloors.isEmpty { d["sport_floors"] = stringKeyed(sportFloors) }
        return d
    }

    private static func familyMap(_ d: [String: Any]) -> [SportFamily: Double] {
        var out: [SportFamily: Double] = [:]
        for (k, v) in d {
            guard let fam = SportFamily(rawValue: k.lowercased()), let n = (v as? NSNumber)?.doubleValue else { continue }
            out[fam] = n
        }
        return out
    }
    private func stringKeyed(_ m: [SportFamily: Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: m.map { ($0.key.rawValue, $0.value) })
    }
}

struct AthletePreferences {
    /// Free-text training likes/dislikes ("Run: likes strides"). Honored by
    /// default when building workouts — guidance, not binding limitations. The
    /// one uniform preference list: former structured fields (morning workouts,
    /// indoor trainer, no-X-days) fold into it as plain entries so every
    /// preference is removable the same way.
    var trainingPreferences: [String] = []

    init() {}

    init(from d: [String: Any]) {
        trainingPreferences = d["training_preferences"] as? [String] ?? []
        trainingPreferences.append(contentsOf: Self.foldLegacyFields(
            morningWorkouts: d["morning_workouts"] as? Bool,
            indoorTrainerAvailable: d["indoor_trainer_available"] as? Bool,
            noSwimDays: d["no_swim_days"] as? [String] ?? [],
            noBikeDays: d["no_bike_days"] as? [String] ?? [],
            noRunDays: d["no_run_days"] as? [String] ?? []))
    }

    func toDict() -> [String: Any] {
        ["training_preferences": trainingPreferences]
    }

    /// Render pre-fold structured preference fields (legacy imports and
    /// pre-migration store rows) as the plain-text entries they map to.
    static func foldLegacyFields(morningWorkouts: Bool?, indoorTrainerAvailable: Bool?,
                                 noSwimDays: [String], noBikeDays: [String], noRunDays: [String]) -> [String] {
        var entries: [String] = []
        if let v = morningWorkouts { entries.append(v ? "prefers morning workouts" : "prefers not to train in the morning") }
        if let v = indoorTrainerAvailable { entries.append(v ? "indoor trainer available" : "no indoor trainer") }
        if !noSwimDays.isEmpty { entries.append("no swim on: \(noSwimDays.joined(separator: ", "))") }
        if !noBikeDays.isEmpty { entries.append("no bike on: \(noBikeDays.joined(separator: ", "))") }
        if !noRunDays.isEmpty { entries.append("no run on: \(noRunDays.joined(separator: ", "))") }
        return entries
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

nonisolated struct Limitation: Codable {
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

    var refId: String { MemoryRef.id(item + "|" + (reason ?? "")) }
}

nonisolated struct InjuryImpact: Codable {
    let injury: String
    let impact: String

    init?(from d: [String: Any]) {
        guard let i = d["injury"] as? String, let imp = d["impact"] as? String else { return nil }
        injury = i; impact = imp
    }

    func toDict() -> [String: Any] { ["injury": injury, "impact": impact] }

    var refId: String { MemoryRef.id(injury + "|" + impact) }
}

// MARK: - Removal handles

/// Stable, token-cheap removal handles for profile entries: a 4-hex-char FNV-1a
/// hash of the entry's content, rendered as "[ab12]" next to each removable item
/// in the prompt context and accepted by the remove_* tool fields. Content-derived,
/// so a handle never shifts when other entries are added or removed — no get
/// round-trip before a remove.
nonisolated enum MemoryRef {
    static func id(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%04x", (hash >> 16) ^ (hash & 0xFFFF))
    }
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
