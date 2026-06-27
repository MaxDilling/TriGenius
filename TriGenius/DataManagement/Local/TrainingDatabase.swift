import Foundation
import SwiftData

extension Notification.Name {
    /// Posted (on the main actor) whenever the local training store is mutated —
    /// activities, performance metrics or scheduled workouts, from any path
    /// (coach tools, a sync, or a user action). Views that render from a cached
    /// snapshot (Dashboard, Calendar, Performance Insights) observe this to reload
    /// without triggering a full network re-sync. Emission is coalesced, so a
    /// burst of mutations (one sync) yields a single notification.
    static let trainingDataDidChange = Notification.Name("trigenius.trainingDataDidChange")
}

// MARK: - Local Time-Series Database
//
// A persistent local store for historical workout data and the single source of
// truth the coach, analytics and UI read from.
//
// `WorkoutRecord` is a TrainingPeaks-style *unified* workout slot: it can carry a
// PLANNED section (targets + structured steps on a future date), a COMPLETED
// section (the finished activity with TSS), or BOTH (a planned session that has
// since been done). `isPlanned` / `isCompleted` flag which sections are present.
// Planned workouts are owned locally and pushed to a write target; each row keeps
// a map of per-target external ids (`externalRefsJSON`) so switching the write
// target can re-push without losing anything.
//
// This is intentionally independent of `coach_memory.json`: the coach memory
// stays the LLM prompt context, while this database is the structured,
// queryable history.

// MARK: - SwiftData model

/// One workout slot — planned, completed, or both. Keyed by a stable id
/// (`garmin:<id>`, `healthkit:<uuid>`, `local:<uuid>`) so repeated syncs upsert
/// instead of duplicating. Completed fields are non-optional with defaults so the
/// analytics layer (which only ever sees completed rows) reads them directly.
@Model
final class WorkoutRecord {
    @Attribute(.unique) var id: String
    /// Origin of the record ("garmin", "healthkit", "local").
    var source: String
    /// Start-of-day date the workout belongs to (local), used for daily buckets.
    var date: Date
    /// Sport key (e.g. "running", "lap_swimming", "Cycling").
    var sport: String
    var name: String
    /// Per-write-target external ids, JSON-encoded: `{"garmin":"123","appleWatch":"<uuid>"}`.
    /// Lets a write-target switch re-push a plan that the new target hasn't seen,
    /// without losing the original.
    var externalRefsJSON: String = "{}"
    /// Local clock start time as minutes after midnight (e.g. 630 = 10:30). For a
    /// planned row it's the planned time-of-day (day-independent, survives a move);
    /// for a completed row it's the actual start, set at ingest from the source's
    /// `"time"` field. Nil → no specific time-of-day (kept in the all-day band).
    var startMinute: Int?

    // MARK: Planned section (present when `isPlanned`)

    /// Whether this row carries a plan (targets / structured steps).
    var isPlanned: Bool = false
    /// Planned duration in minutes (0 when unspecified).
    var targetDurationMinutes: Double = 0
    /// Planned total distance in meters for a distance-goal workout (e.g. a 5000 m
    /// swim), 0 when the plan is purely time-based. Kept alongside the duration so a
    /// distance goal survives re-materialization through `WorkoutPayloadBuilder`
    /// (without it, a re-pushed distance workout collapses to a duration heuristic).
    var targetDistanceMeters: Double = 0
    /// Planned TSS, when known. Nil → estimated from duration at read time.
    var targetTSS: Double?
    /// The workout's structured steps (warmup / repeat blocks / intervals /
    /// cooldown with power/pace/HR targets), JSON-encoded in the compact shape
    /// `PlannedWorkoutStructure` and `PlannedTSS` consume. "[]" when there's no
    /// structure (Garmin-Coach workouts, simple plans).
    var stepsJSON: String = "[]"
    /// Optional free-text description of the planned session.
    var notes: String = ""
    /// Pool length in meters for swim plans, when specified. Nil otherwise.
    var poolLengthMeters: Double?

    // MARK: Completed section (present when `isCompleted`)

    /// Whether this row carries a finished activity.
    var isCompleted: Bool = false
    var durationMinutes: Double = 0
    var distanceKm: Double = 0
    /// TSS — the Training Stress Score driving the PMC. Computed by the store at
    /// ingest against the thresholds current on the workout's own date. Nil when
    /// not yet completed / not scorable.
    var tss: Double?
    var aerobicTE: Double?
    var anaerobicTE: Double?
    /// The full coach-facing record, JSON-encoded, served verbatim by
    /// `get_activities`. "" when this row has no completed activity yet.
    var detailsJSON: String = ""

    init(
        id: String,
        source: String,
        date: Date,
        sport: String,
        name: String,
        externalRefsJSON: String = "{}",
        startMinute: Int? = nil,
        isPlanned: Bool = false,
        targetDurationMinutes: Double = 0,
        targetDistanceMeters: Double = 0,
        targetTSS: Double? = nil,
        stepsJSON: String = "[]",
        notes: String = "",
        poolLengthMeters: Double? = nil,
        isCompleted: Bool = false,
        durationMinutes: Double = 0,
        distanceKm: Double = 0,
        tss: Double? = nil,
        aerobicTE: Double? = nil,
        anaerobicTE: Double? = nil,
        detailsJSON: String = ""
    ) {
        self.id = id
        self.source = source
        self.date = date
        self.sport = sport
        self.name = name
        self.externalRefsJSON = externalRefsJSON
        self.startMinute = startMinute
        self.isPlanned = isPlanned
        self.targetDurationMinutes = targetDurationMinutes
        self.targetDistanceMeters = targetDistanceMeters
        self.targetTSS = targetTSS
        self.stepsJSON = stepsJSON
        self.notes = notes
        self.poolLengthMeters = poolLengthMeters
        self.isCompleted = isCompleted
        self.durationMinutes = durationMinutes
        self.distanceKm = distanceKm
        self.tss = tss
        self.aerobicTE = aerobicTE
        self.anaerobicTE = anaerobicTE
        self.detailsJSON = detailsJSON
    }
}

extension WorkoutRecord {
    /// Per-target external ids decoded from `externalRefsJSON`.
    var externalRefs: [String: String] {
        guard let d = externalRefsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [:] }
        return obj
    }

    /// Parse `"HH:mm"` (the value `GarminService` writes from `startTimeLocal`) into
    /// minutes after midnight. Used at completed-ingest to populate `startMinute`.
    static func clockMinute(fromDetails detailsJSON: String) -> Int? {
        guard let data = detailsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let time = obj["time"] as? String else { return nil }
        let parts = time.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
}

// MARK: - Metric-key namespace
//
// Canonical snake_case keys for the `PerformanceMetricRecord` time series, split
// by purpose. Shared by ingest, the Performance Insights UI and the
// "delete historical performance data" dev action so the sets never drift.
enum MetricKeys {
    /// Physiological capacity markers (FTP, VO2max, thresholds, zones, weight).
    /// Speeds are stored as raw m/s under `*_speed` keys (not pace-seconds); the
    /// pace conversion happens only when building `PerformanceSnapshot` / the UI.
    static let performance: Set<String> = {
        var keys: Set<String> = [
            "cycling_ftp", "running_ftp",
            "vo2max_running", "vo2max_cycling",
            "lactate_threshold_hr", "lactate_threshold_speed",
            "swim_css_speed", "max_hr", "weight_kg",
        ]
        for n in 1...5 {
            keys.insert("hr_zone\(n)_upper")
            keys.insert("power_zone\(n)_upper")
        }
        return keys
    }()

    /// Daily recovery / wellness signals (sleep, resting HR, HRV).
    static let wellness: Set<String> = [
        "resting_hr", "hrv_overnight",
        "sleep_score", "sleep_duration_h",
        "sleep_deep_h", "sleep_light_h", "sleep_rem_h", "sleep_awake_h",
    ]
}

// MARK: - Performance metric model
//
// Performance values (FTP, CSS, lactate thresholds, VO2max, …) are stored as a
// timestamped, append-only time series — the same way Garmin tracks them — so the
// progression over time can be charted and the coach reads the latest value per
// metric from the DB. Daily wellness signals (sleep, resting HR, HRV) live in the
// same series under `MetricKeys.wellness`.

/// One performance value at a point in time. Keyed by a composite
/// "<metricKey>:<source>:<yyyy-MM-dd>" id so repeated same-day syncs upsert
/// instead of duplicating, while different days append to the series.
@Model
final class PerformanceMetricRecord {
    @Attribute(.unique) var id: String
    /// snake_case metric key, e.g. "cycling_ftp", "swim_css_speed", "resting_hr".
    var metricKey: String
    var value: Double
    /// Unit token, e.g. "watts", "bpm", "ml_kg_min", "sec_per_100m".
    var unit: String
    /// Origin of the value ("garmin", "healthkit", "manual").
    var source: String
    /// Start-of-day date the value belongs to (local).
    var date: Date

    init(id: String, metricKey: String, value: Double, unit: String, source: String, date: Date) {
        self.id = id
        self.metricKey = metricKey
        self.value = value
        self.unit = unit
        self.source = source
        self.date = date
    }
}

// MARK: - Ingest DTO

/// Sendable snapshot used to hand activities from the (non-MainActor) data
/// sources to the MainActor-bound store.
struct IngestedActivity: Sendable {
    let id: String
    let source: String
    let date: Date
    let sport: String
    let name: String
    let durationMinutes: Double
    /// Source-declared distance (km); a fallback only — the store re-derives the
    /// effective distance (swim cleaning / manual override) when it scores.
    let distanceKm: Double
    let aerobicTE: Double?
    let anaerobicTE: Double?
    /// Normalized, *unscored* activity JSON. The store computes TSS + the resolved
    /// distance from this at ingest (see `TrainingDataStore.ingest`).
    let detailsJSON: String
}

/// The cached, already-computed result of a stored activity — lets a resync reuse
/// it instead of re-fetching streams / recomputing TSS for a known workout.
struct CachedActivity: Sendable {
    let tss: Double?
    let detailsJSON: String
}

/// Sendable snapshot used to hand planned workouts from the (non-MainActor)
/// data sources / coach tools to the MainActor-bound store. `date` is normalized
/// to start-of-day on ingest.
struct IngestedScheduledWorkout: Sendable {
    let id: String
    let source: String
    let date: Date
    let sport: String
    let name: String
    let targetDurationMinutes: Double
    /// Planned total distance in meters for a distance-goal workout, 0 if time-based.
    var targetDistanceMeters: Double = 0
    let targetTSS: Double?
    let notes: String
    /// Compact structured steps, JSON-encoded (see `WorkoutRecord.stepsJSON`).
    var stepsJSON: String = "[]"
    /// Pool length in meters for swim workouts, when the source specifies one.
    var poolLengthMeters: Double? = nil
    /// The completed activity a source (e.g. Garmin) linked to this plan.
    var associatedActivityId: String? = nil
    /// Per-target external ids, JSON-encoded. Preserved across resyncs.
    var externalRefsJSON: String = "{}"
}

/// One day's aggregated TSS — the unit the PMC engine works on.
struct DailyTSS: Sendable, Identifiable {
    let date: Date
    let totalTSS: Double
    var id: Date { date }
}

/// Sendable performance value handed from the (non-MainActor) data sources to
/// the MainActor-bound store. `date` is normalized to start-of-day on ingest.
struct IngestedMetric: Sendable {
    let metricKey: String
    let value: Double
    let unit: String
    let source: String
    let date: Date
}

/// One performance metric's value on a given day — the unit the Performance
/// Insights progression charts work on.
struct MetricPoint: Sendable, Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// Latest value per performance metric, read from the DB to build the coach's
/// system-prompt context and the Settings display.
struct PerformanceSnapshot: Sendable {
    var cyclingFTP: Int?
    var runningFTP: Int?
    /// Swim critical-swim-speed pace, in seconds per 100 m.
    var cssPaceSeconds: Double?
    var lactateThrHR: Int?
    /// Maximum heart rate, in bpm.
    var maxHR: Int?
    /// Running lactate-threshold pace, in seconds per km.
    var lactateThrPaceSeconds: Double?
    var vo2maxRunning: Double?
    var vo2maxCycling: Double?
    var weightKg: Double?

    /// CSS pace formatted as "m:ss" per 100 m (matches `GarminTransform.speedToPace`).
    var cssPaceFormatted: String? {
        guard let s = cssPaceSeconds, s > 0 else { return nil }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    /// Lactate-threshold pace formatted as "m:ss" per km.
    var lactateThrPaceFormatted: String? {
        guard let s = lactateThrPaceSeconds, s > 0 else { return nil }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

/// The full performance-metric history, queryable as a `PerformanceSnapshot` *as
/// of any date*. A completed activity must be scored against the thresholds that
/// were current on its OWN date — an FTP bump today must not retroactively rescore
/// a January ride — so TSS at ingest reads `snapshot(asOf: activity.date)`, not the
/// latest values. Built once from the store and queried per activity in an ingest
/// loop (avoids a DB round-trip per activity).
struct PerformanceHistory: Sendable {
    /// One dated metric reading, pre-ranked by source so ties resolve the same way
    /// `latestSnapshot` does.
    struct Entry: Sendable {
        let date: Date
        let value: Double
        let rank: Int
    }

    /// metricKey → readings, ascending by date.
    private let byKey: [String: [Entry]]

    init(byKey: [String: [Entry]]) {
        self.byKey = byKey.mapValues { $0.sorted { $0.date < $1.date } }
    }

    /// Value of one metric as it stood on `date`: the newest reading on or before
    /// `date`, ties broken by source rank. Nil when no reading exists yet by then.
    private func value(_ key: String, asOf date: Date) -> Double? {
        guard let entries = byKey[key] else { return nil }
        var best: Entry?
        for e in entries where e.date <= date {
            guard let b = best else { best = e; continue }
            if e.date > b.date || (e.date == b.date && e.rank > b.rank) { best = e }
        }
        return best?.value
    }

    /// The metric snapshot as it stood on `date`, assembled for the TSS engine.
    /// Pass `.distantFuture` to get the latest value of every metric.
    func snapshot(asOf date: Date) -> PerformanceSnapshot {
        var snap = PerformanceSnapshot()
        snap.cyclingFTP = value("cycling_ftp", asOf: date).map { Int($0.rounded()) }
        snap.runningFTP = value("running_ftp", asOf: date).map { Int($0.rounded()) }
        // CSS / LT thresholds are stored as raw speed (m/s); convert to the
        // pace-seconds the snapshot (and the TSS engine) consume.
        if let s = value("swim_css_speed", asOf: date), s > 0 { snap.cssPaceSeconds = 100.0 / s }
        snap.lactateThrHR = value("lactate_threshold_hr", asOf: date).map { Int($0.rounded()) }
        snap.maxHR = value("max_hr", asOf: date).map { Int($0.rounded()) }
        if let s = value("lactate_threshold_speed", asOf: date), s > 0 { snap.lactateThrPaceSeconds = 1000.0 / s }
        snap.vo2maxRunning = value("vo2max_running", asOf: date)
        snap.vo2maxCycling = value("vo2max_cycling", asOf: date)
        snap.weightKg = value("weight_kg", asOf: date)
        return snap
    }
}

// MARK: - Store

/// Owns the `ModelContainer` and provides upsert + query helpers.
/// MainActor-bound because SwiftData's `ModelContext` is not Sendable.
@MainActor
final class TrainingDataStore {
    static let shared = TrainingDataStore()

    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    private init() {
        do {
            container = try ModelContainer(for: WorkoutRecord.self, PerformanceMetricRecord.self)
        } catch {
            // An in-memory fallback keeps the app usable even if the on-disk
            // store can't be opened (e.g. an incompatible migration).
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: WorkoutRecord.self, PerformanceMetricRecord.self, configurations: config)
        }
    }

    /// Coalesces change notifications: every mutating method calls this after its
    /// `context.save()`, but a burst within one runloop tick (a sync that ingests
    /// activities + scheduled + metrics in sequence) collapses into a single post.
    private var changePending = false
    private func markChanged() {
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.async { [weak self] in
            self?.changePending = false
            NotificationCenter.default.post(name: .trainingDataDidChange, object: nil)
        }
    }

    /// Delete every stored record — workouts and performance metrics. The
    /// `coach_memory.json` profile/settings are NOT touched; this only clears the
    /// local time-series database.
    func deleteAllData() {
        try? context.delete(model: WorkoutRecord.self)
        try? context.delete(model: PerformanceMetricRecord.self)
        try? context.save()
        markChanged()
    }

    /// Delete every stored historical performance metric (FTP, VO2max,
    /// thresholds, zones, weight — `MetricKeys.performance`), leaving daily
    /// wellness metrics and workouts intact. Dev action for clearing
    /// noisy/incorrect backfilled performance history.
    func deletePerformanceMetrics() {
        let all = (try? context.fetch(FetchDescriptor<PerformanceMetricRecord>())) ?? []
        let stale = all.filter { MetricKeys.performance.contains($0.metricKey) }
        guard !stale.isEmpty else { return }
        for r in stale { context.delete(r) }
        try? context.save()
        markChanged()
    }

    // MARK: - Completed activities

    /// Upsert a batch of completed activities (insert new, update existing by id),
    /// scoring each one's TSS + effective distance here — the single place it
    /// happens, so every data source gets consistent TSS without knowing about it.
    /// Each activity is scored against `snapshot(asOf: a.date)`, i.e. the thresholds
    /// current on its own date.
    ///
    /// When an activity matches an open plan (the plan's `associatedActivityId`
    /// names it, or — failing that — an open plan on the same day for the same sport
    /// family), the completed section is folded INTO that plan row (TrainingPeaks-
    /// style planned+actual on one row) and no separate activity row is inserted, so
    /// the load is never double-counted.
    func ingest(_ activities: [IngestedActivity]) {
        guard !activities.isEmpty else { return }
        let history = performanceHistory()
        for a in activities {
            let scored = Self.score(a, history: history)
            // 1) An existing row already keyed by this activity id → update in place.
            let id = a.id
            if let record = (try? context.fetch(
                FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })))?.first {
                Self.applyCompleted(scored, of: a, to: record)
                continue
            }
            // 2) Otherwise try to fold it into a matching open plan.
            if let plan = matchingOpenPlan(for: a) {
                Self.applyCompleted(scored, of: a, to: plan)
                plan.setExternalRef(target: Self.completedRefKey, externalId: a.id)
                continue
            }
            // 3) Else insert a fresh completed-only row.
            let rec = WorkoutRecord(
                id: a.id, source: a.source, date: a.date, sport: a.sport, name: a.name,
                startMinute: WorkoutRecord.clockMinute(fromDetails: scored.detailsJSON),
                isCompleted: true,
                durationMinutes: a.durationMinutes, distanceKm: scored.distanceKm,
                tss: scored.tss, aerobicTE: a.aerobicTE, anaerobicTE: a.anaerobicTE,
                detailsJSON: scored.detailsJSON
            )
            context.insert(rec)
        }
        try? context.save()
        markChanged()
    }

    /// Apply a scored completed activity onto an existing row (which may be a plan
    /// gaining its actuals, or a completed row being refreshed). Planned fields are
    /// left untouched.
    private static func applyCompleted(_ scored: (tss: Double?, distanceKm: Double, detailsJSON: String),
                                       of a: IngestedActivity, to record: WorkoutRecord) {
        // Don't downgrade a plan's own date/sport/name to the activity's if it was
        // user-authored; for a plain completed row these just refresh.
        if !record.isPlanned {
            record.source = a.source
            record.date = a.date
            record.sport = a.sport
            record.name = a.name
        }
        record.isCompleted = true
        record.durationMinutes = a.durationMinutes
        record.distanceKm = scored.distanceKm
        record.tss = scored.tss
        record.aerobicTE = a.aerobicTE
        record.anaerobicTE = a.anaerobicTE
        record.detailsJSON = scored.detailsJSON
        if record.startMinute == nil {
            record.startMinute = WorkoutRecord.clockMinute(fromDetails: scored.detailsJSON)
        }
    }

    /// Find an open plan (`isPlanned && !isCompleted`) this activity completes: first
    /// by an explicit Garmin link (`externalRefs["garmin"]` == the activity's raw id),
    /// else the nearest open plan on the same day for the same sport family.
    private func matchingOpenPlan(for a: IngestedActivity) -> WorkoutRecord? {
        let cal = Calendar.current
        let day = cal.startOfDay(for: a.date)
        let openPlans = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isPlanned && !$0.isCompleted && $0.date == day }
        ))) ?? []
        guard !openPlans.isEmpty else { return nil }
        // Explicit provider link wins (the plan named this activity as its completion).
        if let linked = openPlans.first(where: { $0.externalRefs[Self.completedRefKey] == a.id }) {
            return linked
        }
        // Else same sport family, nearest planned start time.
        let family = SportFamily(sportKey: a.sport)
        let candidates = openPlans.filter { SportFamily(sportKey: $0.sport) == family }
        guard !candidates.isEmpty else { return nil }
        let actualStart = WorkoutRecord.clockMinute(fromDetails: a.detailsJSON)
        return candidates.min { lhs, rhs in
            Self.startGap(lhs.startMinute, actualStart) < Self.startGap(rhs.startMinute, actualStart)
        }
    }

    private static func startGap(_ a: Int?, _ b: Int?) -> Int {
        guard let a, let b else { return Int.max / 2 }
        return abs(a - b)
    }

    /// `externalRefs` key holding the completed activity a plan was linked to
    /// (the full stored id, e.g. `garmin:12345`). Kept separate from the write-target
    /// keys (`garmin`/`appleWatch`) so a provider's plan id is never clobbered.
    static let completedRefKey = "completed"

    /// Strip the source prefix from a stored id (`garmin:123` → `123`).
    static func rawId(_ id: String) -> String {
        guard let colon = id.firstIndex(of: ":") else { return id }
        return String(id[id.index(after: colon)...])
    }

    /// Score one incoming activity against the thresholds current on its date.
    private static func score(_ a: IngestedActivity, history: PerformanceHistory)
        -> (tss: Double?, distanceKm: Double, detailsJSON: String) {
        guard var details = jsonObject(a.detailsJSON) else {
            return (nil, a.distanceKm, a.detailsJSON)
        }
        let (km, tss) = TSSScoring.score(&details, snapshot: history.snapshot(asOf: a.date))
        return (tss, km, jsonString(details) ?? a.detailsJSON)
    }

    /// Cached `(tss, detailsJSON)` for the given ids — a resync passes the ids it is
    /// about to fetch so already-stored workouts can be reused without re-fetching
    /// their streams / recomputing TSS. Manual swim-distance corrections survive
    /// resync this way too. Resolves the raw provider id against folded plan rows too.
    func cachedActivities(ids: Set<String>) -> [String: CachedActivity] {
        guard !ids.isEmpty else { return [:] }
        let all = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isCompleted }))) ?? []
        var out: [String: CachedActivity] = [:]
        for r in all {
            if ids.contains(r.id) {
                out[r.id] = CachedActivity(tss: r.tss, detailsJSON: r.detailsJSON)
            }
            // A completed activity folded into a plan is keyed by the plan id; expose
            // it under the linked activity's id too so the resync can still find it.
            if let cid = r.externalRefs[Self.completedRefKey], ids.contains(cid) {
                out[cid] = CachedActivity(tss: r.tss, detailsJSON: r.detailsJSON)
            }
        }
        return out
    }

    /// Manually override one completed activity's distance (km). Persists the manual
    /// value in `detailsJSON` (so it survives resync) and recomputes distance + TSS.
    func overrideDistance(activityId: String, distanceKm: Double) {
        guard let r = (try? context.fetch(
                  FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == activityId })))?.first,
              var details = Self.jsonObject(r.detailsJSON) else { return }
        details["manual_distance_m"] = distanceKm * 1000
        let (km, tss) = TSSScoring.score(&details, snapshot: performanceHistory().snapshot(asOf: r.date))
        r.distanceKm = km
        r.tss = tss
        r.detailsJSON = Self.jsonString(details) ?? r.detailsJSON
        try? context.save()
        markChanged()
    }

    /// Re-score every stored completed activity's TSS + effective distance from its
    /// own `detailsJSON`, against the performance thresholds current on its date.
    /// Purely local and source-independent (no network / re-fetch) — the
    /// "recompute all" action so existing rows pick up tuning changes regardless of
    /// which provider they came from. Manual distance overrides survive (they live
    /// in `detailsJSON` as `manual_distance_m`). Returns the number of rows updated.
    @discardableResult
    func recomputeCompletedScores() -> Int {
        let records = (try? context.fetch(
            FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.isCompleted }))) ?? []
        guard !records.isEmpty else { return 0 }
        let history = performanceHistory()
        var updated = 0
        for r in records {
            guard var details = Self.jsonObject(r.detailsJSON) else { continue }
            let (km, tss) = TSSScoring.score(&details, snapshot: history.snapshot(asOf: r.date))
            r.distanceKm = km
            r.tss = tss
            r.detailsJSON = Self.jsonString(details) ?? r.detailsJSON
            updated += 1
        }
        try? context.save()
        markChanged()
        return updated
    }

    /// Record the athlete's subjective feedback (feel 1–5, RPE 1–10, free-text
    /// note) on a completed activity, stored in `detailsJSON`. Matches the stored id
    /// or a source-prefixed variant of the raw provider id. Returns false when no
    /// matching completed workout exists.
    func setWorkoutFeedback(activityId: String, feel: Int?, rpe: Int?, note: String?) -> Bool {
        let candidates = [activityId, "garmin:\(activityId)", "healthkit:\(activityId)", "local:\(activityId)"]
        guard let r = (try? context.fetch(
                  FetchDescriptor<WorkoutRecord>(predicate: #Predicate { candidates.contains($0.id) && $0.isCompleted })))?.first,
              var details = Self.jsonObject(r.detailsJSON) else { return false }
        if let feel { details["feel"] = feel }
        if let rpe { details["rpe"] = rpe }
        if let note { details["notes"] = note }
        r.detailsJSON = Self.jsonString(details) ?? r.detailsJSON
        try? context.save()
        markChanged()
        return true
    }

    private static func jsonObject(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
    private static func jsonString(_ obj: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Delete `source`-originated completed activities on/after `from` whose id is
    /// not in `keep`. Reconciles the Apple Health import after dropping
    /// Garmin-mirrored workouts at the source. Plan rows (even folded ones) are
    /// untouched — only standalone completed rows are pruned.
    func pruneActivities(source: String, from: Date, keeping keep: Set<String>) {
        let stale = (try? context.fetch(
            FetchDescriptor<WorkoutRecord>(
                predicate: #Predicate { $0.source == source && $0.date >= from && $0.isCompleted && !$0.isPlanned }
            )
        ))?.filter { !keep.contains($0.id) } ?? []
        guard !stale.isEmpty else { return }
        for r in stale { context.delete(r) }
        try? context.save()
        markChanged()
    }

    /// Completed activities on/after `since` (or all), newest first.
    func activities(since: Date? = nil) -> [WorkoutRecord] {
        var descriptor = FetchDescriptor<WorkoutRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        if let since {
            descriptor.predicate = #Predicate { $0.isCompleted && $0.date >= since }
        } else {
            descriptor.predicate = #Predicate { $0.isCompleted }
        }
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Completed activities within `[from, to]` (start-of-day inclusive), newest first.
    func activities(from: Date, to: Date) -> [WorkoutRecord] {
        let cal = Calendar.current
        let lo = cal.startOfDay(for: from)
        let hi = cal.startOfDay(for: to)
        let descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isCompleted && $0.date >= lo && $0.date <= hi },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Total number of stored completed activities.
    var count: Int {
        (try? context.fetchCount(FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.isCompleted }))) ?? 0
    }

    /// Daily total TSS over `[from, to]`, ascending — input for the PMC engine.
    func dailyTSS(from: Date, to: Date) -> [DailyTSS] {
        let descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isCompleted && $0.date >= from && $0.date <= to },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        let cal = Calendar.current
        var totals: [Date: Double] = [:]
        for r in records {
            let day = cal.startOfDay(for: r.date)
            totals[day, default: 0] += r.tss ?? 0
        }
        return totals
            .map { DailyTSS(date: $0.key, totalTSS: $0.value) }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Scheduled (planned) workouts

    /// Upsert a batch of planned workouts (insert new, update existing by id).
    /// Dates are normalized to start-of-day. Updating an existing row leaves any
    /// already-recorded completed section intact (only the plan fields change).
    func ingestScheduled(_ workouts: [IngestedScheduledWorkout]) {
        guard !workouts.isEmpty else { return }
        let cal = Calendar.current
        for w in workouts {
            let id = w.id
            let day = cal.startOfDay(for: w.date)
            if let record = (try? context.fetch(
                FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })))?.first {
                record.source = w.source
                record.date = day
                record.sport = w.sport
                record.name = w.name
                record.isPlanned = true
                record.targetDurationMinutes = w.targetDurationMinutes
                record.targetDistanceMeters = w.targetDistanceMeters
                record.targetTSS = w.targetTSS
                record.notes = w.notes
                record.stepsJSON = w.stepsJSON
                record.poolLengthMeters = w.poolLengthMeters
                record.externalRefsJSON = w.externalRefsJSON
                if let aid = w.associatedActivityId {
                    record.setExternalRef(target: Self.completedRefKey, externalId: "\(w.source):\(aid)")
                    foldStandaloneCompleted(into: record, source: w.source, rawActivityId: aid)
                }
            } else {
                let rec = WorkoutRecord(
                    id: w.id, source: w.source, date: day, sport: w.sport, name: w.name,
                    externalRefsJSON: w.externalRefsJSON,
                    isPlanned: true,
                    targetDurationMinutes: w.targetDurationMinutes, targetDistanceMeters: w.targetDistanceMeters,
                    targetTSS: w.targetTSS,
                    stepsJSON: w.stepsJSON, notes: w.notes, poolLengthMeters: w.poolLengthMeters
                )
                context.insert(rec)
                if let aid = w.associatedActivityId {
                    rec.setExternalRef(target: Self.completedRefKey, externalId: "\(w.source):\(aid)")
                    foldStandaloneCompleted(into: rec, source: w.source, rawActivityId: aid)
                }
            }
        }
        try? context.save()
        markChanged()
    }

    /// When a plan names its completed activity (`associatedActivityId`) but that
    /// activity was already ingested as a standalone completed row (the launch sync
    /// pulls activities before the calendar), fold the actuals into the plan row and
    /// drop the standalone — so a finished plan never shows as both "open plan" and
    /// "completed activity". No-op if the plan is already completed or no standalone
    /// row exists.
    private func foldStandaloneCompleted(into plan: WorkoutRecord, source: String, rawActivityId: String) {
        guard !plan.isCompleted else { return }
        let standaloneId = "\(source):\(rawActivityId)"
        guard let activity = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.id == standaloneId && $0.isCompleted && !$0.isPlanned }
        )))?.first else { return }
        plan.isCompleted = true
        plan.durationMinutes = activity.durationMinutes
        plan.distanceKm = activity.distanceKm
        plan.tss = activity.tss
        plan.aerobicTE = activity.aerobicTE
        plan.anaerobicTE = activity.anaerobicTE
        plan.detailsJSON = activity.detailsJSON
        if plan.startMinute == nil { plan.startMinute = activity.startMinute }
        context.delete(activity)
    }

    /// Planned workouts in `[from, to]` that are still outstanding (not yet
    /// completed). Centralizes the plan/activity de-duplication so the Agenda,
    /// calendar and projections hide a plan the moment its completion lands.
    func openScheduledWorkouts(from: Date, to: Date) -> [WorkoutRecord] {
        let cal = Calendar.current
        let lo = cal.startOfDay(for: from)
        let hi = cal.startOfDay(for: to)
        let descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isPlanned && !$0.isCompleted && $0.date >= lo && $0.date <= hi },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// All planned workouts within `[from, to]` (start-of-day inclusive), ascending —
    /// including ones already completed (a done plan still carries its targets).
    func scheduledWorkouts(from: Date, to: Date) -> [WorkoutRecord] {
        let cal = Calendar.current
        let lo = cal.startOfDay(for: from)
        let hi = cal.startOfDay(for: to)
        let descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isPlanned && $0.date >= lo && $0.date <= hi },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Fetch a single planned workout by id, or nil if it no longer exists.
    func scheduledWorkout(id: String) -> WorkoutRecord? {
        try? context.fetch(
            FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id && $0.isPlanned })
        ).first
    }

    /// Open future-dated, **TriGenius-authored** plans (`source == "local"`, from
    /// `from` onward) that have no external ref for `target` yet — the set
    /// `reconcileWriteTarget` re-pushes after a target switch. Provider-mirrored
    /// plans (e.g. `source == "garmin"`) are deliberately excluded: they already
    /// exist on their origin and are display-only, so re-pushing them would
    /// duplicate the workout on the provider.
    func plansMissingRef(target: String, from: Date) -> [WorkoutRecord] {
        let day = Calendar.current.startOfDay(for: from)
        let open = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isPlanned && !$0.isCompleted && $0.source == "local" && $0.date >= day }
        ))) ?? []
        return open.filter { $0.externalRefs[target] == nil }
    }

    /// Clear the `target` external ref on any open, locally-authored plan within
    /// `[from, to]` whose recorded id is *not* in `present` — i.e. the athlete
    /// deleted TriGenius's copy on the provider. Dropping the dead ref lets
    /// `reconcileWriteTarget` re-create the plan (local plans are the source of
    /// truth). `present` is the set of ids the provider currently has in the window.
    func clearStaleWriteRefs(target: String, present: Set<String>, from: Date, to: Date) {
        let cal = Calendar.current
        let lo = cal.startOfDay(for: from)
        let hi = cal.startOfDay(for: to)
        let plans = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isPlanned && !$0.isCompleted && $0.source == "local" && $0.date >= lo && $0.date <= hi }
        ))) ?? []
        var changed = false
        for p in plans {
            guard let ref = p.externalRefs[target], !present.contains(ref) else { continue }
            p.setExternalRef(target: target, externalId: nil)
            changed = true
        }
        if changed { try? context.save(); markChanged() }
    }

    /// External ids already referenced for `target` by locally-authored plans — used
    /// to skip re-mirroring a provider's copy of a workout TriGenius itself pushed
    /// there (which would otherwise appear twice).
    func externalRefIds(target: String, source: String) -> Set<String> {
        let plans = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isPlanned && $0.source == source }
        ))) ?? []
        return Set(plans.compactMap { $0.externalRefs[target] })
    }

    /// Record (or clear) a plan's external id for a write target.
    func setExternalRef(id: String, target: String, externalId: String?) {
        guard let r = (try? context.fetch(
            FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })))?.first else { return }
        r.setExternalRef(target: target, externalId: externalId)
        try? context.save()
        markChanged()
    }

    /// Reschedule a planned workout to a new day. Returns the updated record.
    @discardableResult
    func moveScheduledWorkout(id: String, to newDate: Date) -> WorkoutRecord? {
        let record = try? context.fetch(
            FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })
        ).first
        guard let record else { return nil }
        record.date = Calendar.current.startOfDay(for: newDate)
        try? context.save()
        markChanged()
        return record
    }

    /// Update a planned workout's content in place (date untouched). Only non-nil
    /// arguments are applied; `targetTSS` is double-optional so `.some(nil)` clears
    /// it while `nil` leaves it unchanged. Returns the updated record.
    @discardableResult
    func updateScheduledContent(id: String, sport: String? = nil, name: String? = nil,
                                targetDurationMinutes: Double? = nil, targetDistanceMeters: Double? = nil,
                                targetTSS: Double?? = nil,
                                notes: String? = nil, stepsJSON: String? = nil) -> WorkoutRecord? {
        let record = try? context.fetch(
            FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })
        ).first
        guard let record else { return nil }
        if let sport { record.sport = sport }
        if let name { record.name = name }
        if let targetDurationMinutes { record.targetDurationMinutes = targetDurationMinutes }
        if let targetDistanceMeters { record.targetDistanceMeters = targetDistanceMeters }
        if let targetTSS { record.targetTSS = targetTSS }
        if let notes { record.notes = notes }
        if let stepsJSON { record.stepsJSON = stepsJSON }
        try? context.save()
        markChanged()
        return record
    }

    /// Set (or clear) a planned workout's local time-of-day, in minutes after
    /// midnight. Returns the updated record.
    @discardableResult
    func setScheduledStartMinute(id: String, minute: Int?) -> WorkoutRecord? {
        let record = try? context.fetch(
            FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })
        ).first
        guard let record else { return nil }
        record.startMinute = minute
        try? context.save()
        markChanged()
        return record
    }

    /// Remove a planned workout by id. If it has already been completed, only the
    /// plan section is dropped — the completed activity is kept.
    func deleteScheduledWorkout(id: String) {
        guard let record = try? context.fetch(
            FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })
        ).first else { return }
        if record.isCompleted {
            record.isPlanned = false
            record.targetDurationMinutes = 0
            record.targetTSS = nil
            record.stepsJSON = "[]"
        } else {
            context.delete(record)
        }
        try? context.save()
        markChanged()
    }

    /// Replace all `source`-originated OPEN plans within `[from, to]` with a fresh
    /// batch — used when re-syncing the Garmin calendar so device-side deletions are
    /// reflected. Completed rows (even folded plans) and locally-authored plans from
    /// other sources are untouched.
    func replaceScheduled(source: String, from: Date, to: Date, with workouts: [IngestedScheduledWorkout]) {
        let cal = Calendar.current
        let lo = cal.startOfDay(for: from)
        let hi = cal.startOfDay(for: to)
        let stale = (try? context.fetch(
            FetchDescriptor<WorkoutRecord>(
                predicate: #Predicate { $0.source == source && $0.isPlanned && !$0.isCompleted && $0.date >= lo && $0.date <= hi }
            )
        )) ?? []
        // Carry over any locally-set time-of-day so it survives the resync.
        let preservedStart = Dictionary(uniqueKeysWithValues:
            stale.compactMap { r in r.startMinute.map { (r.id, $0) } })
        for r in stale { context.delete(r) }
        try? context.save()
        ingestScheduled(workouts)
        for (id, minute) in preservedStart {
            if let r = try? context.fetch(
                FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })
            ).first {
                r.startMinute = minute
            }
        }
        if !preservedStart.isEmpty { try? context.save() }
        markChanged()
    }

    // MARK: - Performance metrics

    /// Upsert a batch of performance metrics. Same (metric, source, day) updates
    /// in place; a new day appends, building the time series.
    func ingestMetrics(_ metrics: [IngestedMetric]) {
        guard !metrics.isEmpty else { return }
        let cal = Calendar.current
        for m in metrics {
            let day = cal.startOfDay(for: m.date)
            let id = "\(m.metricKey):\(m.source):\(DateFormatter.ymd.string(from: day))"
            let existing = try? context.fetch(
                FetchDescriptor<PerformanceMetricRecord>(predicate: #Predicate { $0.id == id })
            ).first
            if let record = existing {
                record.metricKey = m.metricKey
                record.value = m.value
                record.unit = m.unit
                record.source = m.source
                record.date = day
            } else {
                context.insert(PerformanceMetricRecord(
                    id: id, metricKey: m.metricKey, value: m.value, unit: m.unit, source: m.source, date: day
                ))
            }
        }
        try? context.save()
        markChanged()
    }

    /// Source preference when two records share the newest day for a metric.
    private static func sourceRank(_ source: String) -> Int {
        switch source {
        case "garmin": return 3
        case "healthkit": return 2
        default: return 1   // "manual"
        }
    }

    /// The full performance-metric history as a point-in-time–queryable resolver.
    func performanceHistory() -> PerformanceHistory {
        let records = (try? context.fetch(FetchDescriptor<PerformanceMetricRecord>())) ?? []
        var byKey: [String: [PerformanceHistory.Entry]] = [:]
        for r in records {
            byKey[r.metricKey, default: []].append(
                .init(date: r.date, value: r.value, rank: Self.sourceRank(r.source))
            )
        }
        return PerformanceHistory(byKey: byKey)
    }

    /// Latest value per metric key — the source for the coach's prompt context
    /// and the Settings display. Newest date wins; ties break by source rank.
    func latestSnapshot() -> PerformanceSnapshot {
        performanceHistory().snapshot(asOf: .distantFuture)
    }

    /// Ascending day-by-day history for one metric key — the progression the
    /// Performance Insights charts plot.
    func metricHistory(_ key: String) -> [MetricPoint] {
        let records = (try? context.fetch(
            FetchDescriptor<PerformanceMetricRecord>(
                predicate: #Predicate { $0.metricKey == key },
                sortBy: [SortDescriptor(\.date, order: .forward)]
            )
        )) ?? []
        var perDay: [Date: PerformanceMetricRecord] = [:]
        for r in records {
            if let cur = perDay[r.date] {
                if Self.sourceRank(r.source) > Self.sourceRank(cur.source) { perDay[r.date] = r }
            } else {
                perDay[r.date] = r
            }
        }
        return perDay.values
            .map { MetricPoint(date: $0.date, value: $0.value) }
            .sorted { $0.date < $1.date }
    }
}

// MARK: - External-ref mutation (model-side helper)

extension WorkoutRecord {
    /// Set or clear one target's external id in `externalRefsJSON`.
    func setExternalRef(target: String, externalId: String?) {
        var refs = externalRefs
        if let externalId { refs[target] = externalId } else { refs.removeValue(forKey: target) }
        externalRefsJSON = (try? JSONSerialization.data(withJSONObject: refs))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
