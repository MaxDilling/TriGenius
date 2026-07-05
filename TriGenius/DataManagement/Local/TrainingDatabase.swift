import Foundation
import SwiftData
import CoreData

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
//
// CloudKit-readiness (NSPersistentCloudKitContainer): every `@Model` here keeps
// `id` (and the other natural keys) as a *plain* attribute — no
// `@Attribute(.unique)`, which CloudKit can't enforce — and gives every stored
// attribute a default. Single-device dedup is handled by the fetch-by-id upsert
// in every ingest path; `TrainingDataStore.deduplicate()` is the safety net for
// the duplicates a CloudKit merge of two offline devices can create.

/// One workout slot — planned, completed, or both. Keyed by a stable id
/// (`garmin:<id>`, `healthkit:<uuid>`, `local:<uuid>`) so repeated syncs upsert
/// instead of duplicating. Completed fields are non-optional with defaults so the
/// analytics layer (which only ever sees completed rows) reads them directly.
@Model
final class WorkoutRecord {
    var id: String = ""
    /// Origin of the record ("garmin", "healthkit", "local").
    var source: String = ""
    /// Start-of-day date the workout belongs to (local), used for daily buckets.
    var date: Date = Date.distantPast
    /// Sport key (e.g. "running", "lap_swimming", "Cycling").
    var sport: String = ""
    var name: String = ""
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
    /// How `tss` was derived (e.g. "normalized power vs FTP", "heart-rate zone
    /// load") — surfaced so a fallback-derived score isn't over-trusted. Nil when
    /// not scored. Set alongside `tss` at ingest.
    var tssBasis: String?
    var aerobicTE: Double?
    var anaerobicTE: Double?
    /// The full activity record, JSON-encoded — the rich blob the detail UI reads
    /// and the coach's lean `get_workouts` projection is derived from. "" when this
    /// row has no completed activity yet.
    var detailsJSON: String = ""
    /// Max-mean power per grid duration, computed at ingest from the source's raw
    /// power stream (`PowerCurve.encode`). "" when the activity has no power stream.
    var powerCurveJSON: String = ""

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
        tssBasis: String? = nil,
        aerobicTE: Double? = nil,
        anaerobicTE: Double? = nil,
        detailsJSON: String = "",
        powerCurveJSON: String = ""
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
        self.tssBasis = tssBasis
        self.aerobicTE = aerobicTE
        self.anaerobicTE = anaerobicTE
        self.detailsJSON = detailsJSON
        self.powerCurveJSON = powerCurveJSON
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
    var id: String = ""
    /// snake_case metric key, e.g. "cycling_ftp", "swim_css_speed", "resting_hr".
    var metricKey: String = ""
    var value: Double = 0
    /// Unit token, e.g. "watts", "bpm", "ml_kg_min", "sec_per_100m".
    var unit: String = ""
    /// Origin of the value ("garmin", "healthkit", "manual").
    var source: String = ""
    /// Start-of-day date the value belongs to (local).
    var date: Date = Date.distantPast

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
    /// Encoded max-mean power curve (`PowerCurve.encode`), "" when the source has
    /// no power stream for this activity.
    let powerCurveJSON: String
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

    /// On-disk path of the backing store (debug display); "in-memory store" for the
    /// fallback configuration.
    var storeFilePath: String {
        container.configurations.first?.url.path ?? "in-memory store"
    }

    private init() {
        do {
            // The on-disk store mirrors into the private CloudKit database, so the
            // athlete's history/plan/coach-memory follow them across devices. SwiftData
            // syncs silently when signed into iCloud and degrades to a plain local store
            // when not — no code path change either way.
            let config = ModelConfiguration(
                schema: TrainingDataStore.schema,
                cloudKitDatabase: .private("iCloud.net.Narica.TriGenius")
            )
            container = try ModelContainer(for: TrainingDataStore.schema, configurations: config)
        } catch {
            // An in-memory fallback keeps the app usable even if the on-disk
            // store can't be opened (e.g. an incompatible migration). No CloudKit here.
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: TrainingDataStore.schema, configurations: config)
        }
        observeRemoteChanges()
    }

    /// A CloudKit merge lands in the store asynchronously; SwiftData posts
    /// `.NSPersistentStoreRemoteChange` when it does — but also for this process's
    /// *own* writes (mirroring/export activity), so launch + sync produce long
    /// notification bursts. Debounced to quiescence: one `deduplicate()` per burst,
    /// 1.5 s after the last notification, instead of one per runloop tick.
    private var dedupDebounce: Task<Void, Never>?
    private func observeRemoteChanges() {
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Perf.event("remoteChange")
                guard let self else { return }
                self.dedupDebounce?.cancel()
                self.dedupDebounce = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    self.deduplicate()
                }
            }
        }
    }

    /// Every `@Model` the store owns: the workout/metric time series, the ATP
    /// inputs, and the coach-memory rows (migrated out of `coach_memory.json`).
    static let schema = Schema([
        WorkoutRecord.self, PerformanceMetricRecord.self,
        ATPConfig.self, ATPEvent.self, ATPWeekOverride.self,
        ProfileRecord.self, WeeklyStructureRecord.self, PreferencesRecord.self,
        SportProgressRecord.self, FeedbackRecord.self,
    ])

    /// Coalesces change notifications: every mutating method calls this after its
    /// `context.save()`, but a burst within one runloop tick (a sync that ingests
    /// activities + scheduled + metrics in sequence) collapses into a single post.
    private var changePending = false
    private func markChanged() {
        cachedLatestSnapshot = nil
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.async { [weak self] in
            self?.changePending = false
            Perf.event("trainingDataDidChange")
            NotificationCenter.default.post(name: .trainingDataDidChange, object: nil)
        }
    }

    // MARK: - Cross-device dedup
    //
    // The `@Attribute(.unique)` constraints were dropped for CloudKit (which can't
    // enforce them). On a single device the fetch-by-id upsert in every ingest path
    // already prevents duplicates; these passes are the safety net for the duplicates
    // a CloudKit merge of two offline devices can produce. Idempotent — a no-op on a
    // store with none. The per-type passes don't save; the caller's `context.save()`
    // covers them. `deduplicate()` is the standalone entry `observeRemoteChanges()`
    // fires after every CloudKit merge.

    /// Collapse duplicate rows across every model down to one per natural key.
    /// Idempotent; saves + notifies only when a duplicate was actually removed —
    /// a no-op pass must not claim "data changed" (that fed the launch reload storm).
    func deduplicate() {
        let perf = Perf.begin("deduplicate"); defer { Perf.end(perf) }
        dedupeWorkouts()
        dedupe(PerformanceMetricRecord.self) { $0.id }
        dedupe(ATPConfig.self) { $0.id }
        dedupe(ATPEvent.self) { $0.id }
        dedupe(ATPWeekOverride.self) { DateFormatter.ymd.string(from: $0.weekStart) }
        dedupe(ProfileRecord.self) { $0.id }
        dedupe(WeeklyStructureRecord.self) { $0.id }
        dedupe(PreferencesRecord.self) { $0.id }
        dedupe(SportProgressRecord.self) { $0.sport }
        dedupe(FeedbackRecord.self) { $0.id }
        guard context.hasChanges else { return }
        try? context.save()
        markChanged()
    }

    /// Delete all but the first row per natural `key` for a model type. The kept row
    /// is arbitrary among equals — fine for the value-equivalent keys (a metric/day,
    /// an ATP input); workouts get their own ref-merging pass below. Does not save.
    private func dedupe<T: PersistentModel>(_ type: T.Type, key: (T) -> String) {
        let all = (try? context.fetch(FetchDescriptor<T>())) ?? []
        guard all.count > 1 else { return }
        var seen = Set<String>()
        for row in all where !seen.insert(key(row)).inserted { context.delete(row) }
    }

    /// Keep the most-complete row per workout id, folding any external ref the
    /// dropped duplicate carried onto the survivor (so a write-target id is never
    /// lost). Does not save.
    private func dedupeWorkouts() {
        let all = (try? context.fetch(FetchDescriptor<WorkoutRecord>())) ?? []
        guard all.count > 1 else { return }
        var winners: [String: WorkoutRecord] = [:]
        for row in all {
            guard let current = winners[row.id] else { winners[row.id] = row; continue }
            let winner = Self.moreComplete(current, row) ? current : row
            let loser = winner === current ? row : current
            for (k, v) in loser.externalRefs where winner.externalRefs[k] == nil {
                winner.setExternalRef(target: k, externalId: v)
            }
            winners[row.id] = winner
            context.delete(loser)
        }
    }

    /// Order two same-id rows by how much they carry: a completed section beats a
    /// plan-only row, a plan beats neither, then the richer `detailsJSON` wins.
    private static func moreComplete(_ a: WorkoutRecord, _ b: WorkoutRecord) -> Bool {
        if a.isCompleted != b.isCompleted { return a.isCompleted }
        if a.isPlanned != b.isPlanned { return a.isPlanned }
        return a.detailsJSON.count >= b.detailsJSON.count
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

    /// Erase the training time series and the whole ATP for the in-app "Delete all
    /// my data" (Guideline 5.1.1-v). Coach-memory rows are reset separately via
    /// `CoachMemory.reset()`; the CloudKit mirror deletes in step.
    func deleteTrainingAndATP() {
        try? context.delete(model: WorkoutRecord.self)
        try? context.delete(model: PerformanceMetricRecord.self)
        try? context.delete(model: ATPConfig.self)
        try? context.delete(model: ATPEvent.self)
        try? context.delete(model: ATPWeekOverride.self)
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
        let perf = Perf.begin("ingest", "\(activities.count)"); defer { Perf.end(perf) }
        let history = performanceHistory()
        let ignored = IgnoredWorkouts.ids
        for a in activities {
            // Blacklisted by the athlete → never give it a row (so it stays gone from
            // every surface and never re-syncs). Checked before scoring/folding.
            if ignored.contains(a.id) { continue }
            let scored = Self.score(a, history: history)
            let id = a.id
            // 1) Already folded into a completed plan (its actuals live on the plan
            // row, keyed by `completedRef` — not by this id) → refresh that plan and
            // drop any stray standalone with this id, never re-insert. Checked before
            // the id-match so that a duplicate the old fold path left behind self-heals;
            // without it a same-day re-sync re-creates the standalone the fold absorbed.
            if let plan = foldedPlan(forActivityId: id, on: a.date) {
                Self.applyCompleted(scored, of: a, to: plan)
                if let stray = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
                    predicate: #Predicate { $0.id == id && !$0.isPlanned })))?.first {
                    context.delete(stray)
                }
                continue
            }
            // 2) An existing row already keyed by this activity id → update in place.
            if let record = (try? context.fetch(
                FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })))?.first {
                Self.applyCompleted(scored, of: a, to: record)
                continue
            }
            // 3) Otherwise try to fold it into a matching open plan.
            if let plan = matchingOpenPlan(for: a) {
                Self.applyCompleted(scored, of: a, to: plan)
                plan.setExternalRef(target: Self.completedRefKey, externalId: a.id)
                continue
            }
            // 4) Else insert a fresh completed-only row.
            let rec = WorkoutRecord(
                id: a.id, source: a.source, date: a.date, sport: a.sport, name: a.name,
                startMinute: WorkoutRecord.clockMinute(fromDetails: scored.detailsJSON),
                isCompleted: true,
                durationMinutes: a.durationMinutes, distanceKm: scored.distanceKm,
                tss: scored.tss, tssBasis: scored.basis, aerobicTE: a.aerobicTE, anaerobicTE: a.anaerobicTE,
                detailsJSON: scored.detailsJSON, powerCurveJSON: a.powerCurveJSON
            )
            context.insert(rec)
        }
        dedupeWorkouts()
        try? context.save()
        markChanged()
    }

    /// Apply a scored completed activity onto an existing row (which may be a plan
    /// gaining its actuals, or a completed row being refreshed). Planned fields are
    /// left untouched.
    private static func applyCompleted(_ scored: (tss: Double?, distanceKm: Double, detailsJSON: String, basis: String?),
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
        record.tssBasis = scored.basis
        record.aerobicTE = a.aerobicTE
        record.anaerobicTE = a.anaerobicTE
        record.detailsJSON = scored.detailsJSON
        record.powerCurveJSON = a.powerCurveJSON
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

    /// The completed plan that already absorbed the activity `id` (folded, so its
    /// actuals live on the plan via `completedRef`). `externalRefs` is JSON-decoded,
    /// so it can't be a `#Predicate`; the day filter (the fold is same-day) bounds the
    /// scan. Used by ingest to refresh rather than duplicate an already-folded actual.
    private func foldedPlan(forActivityId id: String, on date: Date) -> WorkoutRecord? {
        let day = Calendar.current.startOfDay(for: date)
        let plans = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isPlanned && $0.isCompleted && $0.date == day }
        ))) ?? []
        return plans.first { $0.externalRefs[Self.completedRefKey] == id }
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
        -> (tss: Double?, distanceKm: Double, detailsJSON: String, basis: String?) {
        guard var details = jsonObject(a.detailsJSON) else {
            return (nil, a.distanceKm, a.detailsJSON, nil)
        }
        let (km, tss, basis) = TSSScoring.score(&details, snapshot: history.snapshot(asOf: a.date))
        return (tss, km, jsonString(details) ?? a.detailsJSON, basis)
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
        let (km, tss, basis) = TSSScoring.score(&details, snapshot: performanceHistory().snapshot(asOf: r.date))
        r.distanceKm = km
        r.tss = tss
        r.tssBasis = basis
        r.detailsJSON = Self.jsonString(details) ?? r.detailsJSON
        try? context.save()
        markChanged()
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
        dedupeWorkouts()
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
        fold(activity: activity, into: plan)
    }

    /// Fold a standalone completed `activity` into an open `plan`: copy its actuals
    /// onto the plan, link it (`completedRef`) and drop the standalone — the single
    /// place a separate completed row collapses into its plan, shared by the
    /// calendar-driven `foldStandaloneCompleted` and the manual `linkActual`.
    private func fold(activity: WorkoutRecord, into plan: WorkoutRecord) {
        plan.isCompleted = true
        plan.durationMinutes = activity.durationMinutes
        plan.distanceKm = activity.distanceKm
        plan.tss = activity.tss
        plan.tssBasis = activity.tssBasis
        plan.aerobicTE = activity.aerobicTE
        plan.anaerobicTE = activity.anaerobicTE
        plan.detailsJSON = activity.detailsJSON
        plan.powerCurveJSON = activity.powerCurveJSON
        if plan.startMinute == nil { plan.startMinute = activity.startMinute }
        plan.setExternalRef(target: Self.completedRefKey, externalId: activity.id)
        context.delete(activity)
    }

    // MARK: - Manual pairing override
    //
    // The automatic ingest fold pairs a completed activity to a plan by the
    // provider's explicit link or a same-day/same-sport/nearest-start heuristic.
    // When that heuristic picks the wrong actual — e.g. a plan run on the Apple
    // Watch but a parallel Garmin session ingested first — these two let the
    // athlete correct it by hand: split the wrong pairing, then attach the right
    // activity.

    /// Split a folded plan row (`isPlanned && isCompleted`) back into an open plan
    /// and a standalone completed activity. The actual is re-materialized as its own
    /// row keyed by the completion id (`externalRefs["completed"]`), so it is
    /// preserved and re-upserts in place on the next provider sync (which re-heals
    /// the source/name the plan overrode at fold time); the plan returns to open.
    /// No-op unless the row is a folded plan carrying a completion link.
    func unlinkActual(planId: String) {
        guard let plan = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
                  predicate: #Predicate { $0.id == planId && $0.isPlanned && $0.isCompleted }
              )))?.first,
              let activityId = plan.externalRefs[Self.completedRefKey] else { return }
        let activity = WorkoutRecord(
            id: activityId,
            source: activityId.components(separatedBy: ":").first ?? plan.source,
            date: plan.date, sport: plan.sport, name: plan.name,
            startMinute: WorkoutRecord.clockMinute(fromDetails: plan.detailsJSON),
            isCompleted: true,
            durationMinutes: plan.durationMinutes, distanceKm: plan.distanceKm,
            tss: plan.tss, tssBasis: plan.tssBasis, aerobicTE: plan.aerobicTE, anaerobicTE: plan.anaerobicTE,
            detailsJSON: plan.detailsJSON, powerCurveJSON: plan.powerCurveJSON
        )
        context.insert(activity)
        plan.isCompleted = false
        plan.durationMinutes = 0
        plan.distanceKm = 0
        plan.tss = nil
        plan.tssBasis = nil
        plan.aerobicTE = nil
        plan.anaerobicTE = nil
        plan.detailsJSON = ""
        plan.powerCurveJSON = ""
        plan.setExternalRef(target: Self.completedRefKey, externalId: nil)
        try? context.save()
        markChanged()
    }

    /// Fold a standalone completed activity into an open plan by hand — the
    /// athlete-driven counterpart to the automatic ingest fold. No-op unless the
    /// activity is a standalone completed row and the target an open plan.
    func linkActual(activityId: String, toPlanId planId: String) {
        guard let activity = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
                  predicate: #Predicate { $0.id == activityId && $0.isCompleted && !$0.isPlanned }
              )))?.first,
              let plan = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
                  predicate: #Predicate { $0.id == planId && $0.isPlanned && !$0.isCompleted }
              )))?.first else { return }
        fold(activity: activity, into: plan)
        try? context.save()
        markChanged()
    }

    /// Open plans (`isPlanned && !isCompleted`) on the same day and sport family as
    /// `activity` — the candidates the detail view offers for a manual link.
    func openPlansMatching(activity: WorkoutRecord) -> [WorkoutRecord] {
        let day = Calendar.current.startOfDay(for: activity.date)
        let plans = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isPlanned && !$0.isCompleted && $0.date == day }
        ))) ?? []
        let family = SportFamily(sportKey: activity.sport)
        return plans.filter { SportFamily(sportKey: $0.sport) == family }
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

    /// Fetch a single completed activity by id — the stored id or the raw
    /// provider id the coach sees (completed rows are keyed `source:rawId`).
    /// Falls back to folded plan rows, whose linked activity id lives in
    /// `externalRefs` (see `cachedActivities`).
    func activity(id: String) -> WorkoutRecord? {
        let candidates = [id, "garmin:\(id)", "healthkit:\(id)", "local:\(id)"]
        if let hit = (try? context.fetch(
            FetchDescriptor<WorkoutRecord>(predicate: #Predicate { candidates.contains($0.id) && $0.isCompleted })
        ))?.first { return hit }
        return (try? context.fetch(
            FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.isCompleted })
        ))?.first { rec in
            rec.externalRefs[Self.completedRefKey].map { candidates.contains($0) } == true
        }
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

    /// Every external id still referenced for `target` by a planned row (any
    /// source) — the live set `reconcileWriteTarget` keeps when pruning. Anything a
    /// target has scheduled outside this set is an orphan: a plan since deleted, or a
    /// ref lost to a store reset. Folded completed rows keep `isPlanned`, so a
    /// finished workout's ref is retained and never pruned mid-flight.
    func liveExternalRefIds(target: String) -> Set<String> {
        let plans = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isPlanned }
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

    /// Delete one workout row outright by id (debug action). Used by the detail
    /// view's debug-mode delete to force a clean re-create on the next re-sync —
    /// confirming the ingest path actually rebuilds the record. Returns whether a
    /// row was removed.
    @discardableResult
    func deleteActivity(id: String) -> Bool {
        guard let record = try? context.fetch(
            FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })
        ).first else { return false }
        context.delete(record)
        try? context.save()
        markChanged()
        return true
    }

    /// Blacklist a completed activity and drop its row — `ingest` then skips this id
    /// on every future sync, so the workout stays hidden (see `IgnoredWorkouts`). For
    /// a duplicate session recorded on a second device. No-op if the row is missing.
    func ignoreActivity(id: String) {
        guard let record = (try? context.fetch(
            FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })))?.first else { return }
        IgnoredWorkouts.add(IgnoredWorkout(
            id: record.id, name: record.name, date: record.date,
            sport: record.sport, source: record.source))
        context.delete(record)
        try? context.save()
        markChanged()
    }

    /// Remove a workout from the blacklist. The row reappears on the next full
    /// re-sync of its source (the caller triggers that — an incremental sync won't
    /// re-fetch past its watermark).
    func restoreIgnoredWorkout(id: String) {
        IgnoredWorkouts.remove(id: id)
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
        dedupe(PerformanceMetricRecord.self) { $0.id }
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

    /// Latest value per metric key — the source for the coach's prompt context,
    /// the Settings display, and the planned-workout estimators. Cached because the
    /// estimators read it per list row; `markChanged()` invalidates on any mutation.
    private var cachedLatestSnapshot: PerformanceSnapshot?
    func latestSnapshot() -> PerformanceSnapshot {
        if let cached = cachedLatestSnapshot { return cached }
        let snap = performanceHistory().snapshot(asOf: .distantFuture)
        cachedLatestSnapshot = snap
        return snap
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

// MARK: - Annual Training Plan (ATP) store API
//
// Only inputs persist: a singleton config, the events, and sparse per-week
// overrides (see `ATPModels.swift`). Reads return Sendable DTOs for the pure
// engine; every mutation posts `trainingDataDidChange` so derived views recompute.
// Kept in this file so the API can reach the store's private `context` /
// `markChanged()`. ATP is plan config, not time-series, so `deleteAllData()`
// leaves it intact.
extension TrainingDataStore {

    // MARK: Config (singleton)

    private func atpConfigRecord() -> ATPConfig? {
        try? context.fetch(FetchDescriptor<ATPConfig>()).first
    }

    /// The ATP config as a DTO, or nil when no plan exists yet.
    func atpParams() -> ATPParams? {
        atpConfigRecord().map {
            ATPParams(startDate: $0.startDate, startingCTL: $0.startingCTL,
                      methodology: $0.methodology, recoveryCycle: $0.recoveryCycle,
                      maxRampRate: $0.maxRampRate, weeklyAverageTSS: $0.weeklyAverageTSS)
        }
    }

    /// Create or update the singleton ATP config.
    func saveATPParams(_ p: ATPParams) {
        let record: ATPConfig
        if let existing = atpConfigRecord() {
            record = existing
        } else {
            record = ATPConfig(startDate: p.startDate, methodology: p.methodology)
            context.insert(record)
        }
        record.startDate = p.startDate
        record.startingCTL = p.startingCTL
        record.methodology = p.methodology
        record.recoveryCycle = p.recoveryCycle
        record.maxRampRate = p.maxRampRate
        record.weeklyAverageTSS = p.weeklyAverageTSS
        try? context.save()
        markChanged()
    }

    // MARK: Events

    /// All ATP events, ascending by date.
    func atpEvents() -> [ATPEventInput] {
        let descriptor = FetchDescriptor<ATPEvent>(sortBy: [SortDescriptor(\.date, order: .forward)])
        return ((try? context.fetch(descriptor)) ?? []).map {
            ATPEventInput(id: $0.id, name: $0.name, date: $0.date, eventType: $0.eventType,
                          priority: $0.priority, targetCTL: $0.targetCTL, notes: $0.notes)
        }
    }

    /// Insert a new event or update the existing one with the same id.
    func upsertATPEvent(_ e: ATPEventInput) {
        let id = e.id
        if let record = (try? context.fetch(
            FetchDescriptor<ATPEvent>(predicate: #Predicate { $0.id == id })))?.first {
            record.name = e.name
            record.date = e.date
            record.eventType = e.eventType
            record.priority = e.priority
            record.targetCTL = e.targetCTL
            record.notes = e.notes
        } else {
            context.insert(ATPEvent(id: e.id, name: e.name, date: e.date, eventType: e.eventType,
                                    priority: e.priority, targetCTL: e.targetCTL, notes: e.notes))
        }
        try? context.save()
        markChanged()
    }

    /// Remove an event by id. No-op if it's gone.
    func deleteATPEvent(id: String) {
        guard let record = (try? context.fetch(
            FetchDescriptor<ATPEvent>(predicate: #Predicate { $0.id == id })))?.first else { return }
        context.delete(record)
        try? context.save()
        markChanged()
    }

    // MARK: Week overrides (sparse)

    /// All week overrides, ascending by week.
    func atpOverrides() -> [ATPWeekOverrideInput] {
        let descriptor = FetchDescriptor<ATPWeekOverride>(sortBy: [SortDescriptor(\.weekStart, order: .forward)])
        return ((try? context.fetch(descriptor)) ?? []).map {
            ATPWeekOverrideInput(weekStart: $0.weekStart, pinnedTSS: $0.pinnedTSS, note: $0.note)
        }
    }

    /// Pin a week's TSS (0 = rest/vacation), upserting by week start. The week is
    /// snapped to its Monday so the key is stable regardless of the day passed in.
    func setATPOverride(weekStart: Date, pinnedTSS: Double, note: String = "") {
        let monday = TrainingVolume.weekStart(of: weekStart)
        if let existing = (try? context.fetch(
            FetchDescriptor<ATPWeekOverride>(predicate: #Predicate { $0.weekStart == monday })))?.first {
            existing.pinnedTSS = pinnedTSS
            existing.note = note
        } else {
            context.insert(ATPWeekOverride(weekStart: monday, pinnedTSS: pinnedTSS, note: note))
        }
        try? context.save()
        markChanged()
    }

    /// Remove a week's pin. No-op if none.
    func clearATPOverride(weekStart: Date) {
        let monday = TrainingVolume.weekStart(of: weekStart)
        guard let record = (try? context.fetch(
            FetchDescriptor<ATPWeekOverride>(predicate: #Predicate { $0.weekStart == monday })))?.first else { return }
        context.delete(record)
        try? context.save()
        markChanged()
    }

    /// Drop every week pin (Save ATP resets all manual bar overrides).
    func clearAllATPOverrides() {
        let all = (try? context.fetch(FetchDescriptor<ATPWeekOverride>())) ?? []
        guard !all.isEmpty else { return }
        for record in all { context.delete(record) }
        try? context.save()
        markChanged()
    }
}

// MARK: - Coach-memory store API
//
// The athlete's prompt context, migrated out of coach_memory.json into the rows
// in `CoachMemoryModels.swift` so it rides the same CloudKit sync. Kept here (like
// the ATP API) so it can reach the store's private `context` / `markChanged()`.
// `CoachMemory` is the façade that maps these rows to the value structs the app
// consumes; `deleteAllData()` leaves them intact. The struct↔record field mapping
// lives in the `apply`/`make` helpers, shared by the per-section savers and the
// full-restore `replaceCoachMemory`.
extension TrainingDataStore {

    // MARK: Reads

    /// The athlete profile plus the onboarding flag. Defaults when no row exists.
    func coachProfile() -> (profile: UserProfile, onboardingComplete: Bool) {
        guard let r = try? context.fetch(FetchDescriptor<ProfileRecord>()).first else {
            return (UserProfile(), false)
        }
        var p = UserProfile()
        p.name = r.name
        p.goals = r.goals
        if let lat = r.latitude, let lon = r.longitude { p.coordinates = (lat, lon) }
        return (p, r.onboardingComplete)
    }

    func coachWeeklyStructure() -> WeeklyStructure {
        guard let r = try? context.fetch(FetchDescriptor<WeeklyStructureRecord>()).first else {
            return WeeklyStructure()
        }
        var w = WeeklyStructure()
        w.maxHours = r.maxHours
        w.preferredRestDay = r.preferredRestDay
        w.longRunDay = r.longRunDay
        w.longRideDay = r.longRideDay
        w.sportRatio = Self.familyMap(r.sportRatio)
        w.sportFloors = Self.familyMap(r.sportFloors)
        return w
    }

    func coachPreferences() -> AthletePreferences {
        guard let r = try? context.fetch(FetchDescriptor<PreferencesRecord>()).first else {
            return AthletePreferences()
        }
        var p = AthletePreferences()
        p.noSwimDays = r.noSwimDays
        p.noBikeDays = r.noBikeDays
        p.noRunDays = r.noRunDays
        p.morningWorkouts = r.morningWorkouts
        p.indoorTrainerAvailable = r.indoorTrainerAvailable
        return p
    }

    func coachSportProgress() -> SportProgressMap {
        let rows = (try? context.fetch(FetchDescriptor<SportProgressRecord>())) ?? []
        var map = SportProgressMap()
        for r in rows { map.setProgress(Self.make(from: r), for: r.sport) }
        return map
    }

    func coachFeedback() -> [FeedbackEntry] {
        let rows = (try? context.fetch(FetchDescriptor<FeedbackRecord>(
            sortBy: [SortDescriptor(\.date, order: .forward)]))) ?? []
        return rows.map { FeedbackEntry(date: $0.date, category: $0.category, feedback: $0.feedback) }
    }

    /// Whether any coach-memory row exists yet — gates the one-time JSON import.
    var hasCoachMemory: Bool {
        let counts = [
            (try? context.fetchCount(FetchDescriptor<ProfileRecord>())) ?? 0,
            (try? context.fetchCount(FetchDescriptor<WeeklyStructureRecord>())) ?? 0,
            (try? context.fetchCount(FetchDescriptor<PreferencesRecord>())) ?? 0,
            (try? context.fetchCount(FetchDescriptor<SportProgressRecord>())) ?? 0,
            (try? context.fetchCount(FetchDescriptor<FeedbackRecord>())) ?? 0,
        ]
        return counts.contains { $0 > 0 }
    }

    // MARK: Writes (one section each, mirroring CoachMemory's mutators)

    func saveCoachProfile(_ p: UserProfile, onboardingComplete: Bool) {
        let r = (try? context.fetch(FetchDescriptor<ProfileRecord>()).first) ?? {
            let new = ProfileRecord(); context.insert(new); return new
        }()
        Self.apply(p, onboardingComplete: onboardingComplete, to: r)
        try? context.save(); markChanged()
    }

    func saveCoachWeeklyStructure(_ w: WeeklyStructure) {
        let r = (try? context.fetch(FetchDescriptor<WeeklyStructureRecord>()).first) ?? {
            let new = WeeklyStructureRecord(); context.insert(new); return new
        }()
        Self.apply(w, to: r)
        try? context.save(); markChanged()
    }

    func saveCoachPreferences(_ p: AthletePreferences) {
        let r = (try? context.fetch(FetchDescriptor<PreferencesRecord>()).first) ?? {
            let new = PreferencesRecord(); context.insert(new); return new
        }()
        Self.apply(p, to: r)
        try? context.save(); markChanged()
    }

    func saveCoachSportProgress(_ p: SportProgress, for sport: String) {
        let key = sport.lowercased()
        let r = (try? context.fetch(FetchDescriptor<SportProgressRecord>(
            predicate: #Predicate { $0.sport == key })).first) ?? {
            let new = SportProgressRecord(sport: key); context.insert(new); return new
        }()
        Self.apply(p, to: r)
        try? context.save(); markChanged()
    }

    /// Append one feedback entry and trim to the newest `cap` rows.
    func appendCoachFeedback(_ e: FeedbackEntry, cap: Int) {
        context.insert(FeedbackRecord(date: e.date, category: e.category, feedback: e.feedback))
        let rows = (try? context.fetch(FetchDescriptor<FeedbackRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        if rows.count > cap { for r in rows[cap...] { context.delete(r) } }
        try? context.save(); markChanged()
    }

    /// Full restore from an imported coach_memory.json — wipe every coach-memory
    /// row, then write the supplied state. Matches `importJSON`'s replace-not-merge
    /// semantics. Leaves the time-series / ATP rows untouched.
    func replaceCoachMemory(profile: UserProfile, onboardingComplete: Bool,
                            weeklyStructure: WeeklyStructure, preferences: AthletePreferences,
                            sportProgress: SportProgressMap, feedback: [FeedbackEntry]) {
        try? context.delete(model: ProfileRecord.self)
        try? context.delete(model: WeeklyStructureRecord.self)
        try? context.delete(model: PreferencesRecord.self)
        try? context.delete(model: SportProgressRecord.self)
        try? context.delete(model: FeedbackRecord.self)

        let pr = ProfileRecord(); Self.apply(profile, onboardingComplete: onboardingComplete, to: pr)
        context.insert(pr)
        let wr = WeeklyStructureRecord(); Self.apply(weeklyStructure, to: wr); context.insert(wr)
        let prefR = PreferencesRecord(); Self.apply(preferences, to: prefR); context.insert(prefR)
        for sport in sportProgress.toDict().keys {
            let sr = SportProgressRecord(sport: sport.lowercased())
            Self.apply(sportProgress.progress(for: sport), to: sr)
            context.insert(sr)
        }
        for e in feedback {
            context.insert(FeedbackRecord(date: e.date, category: e.category, feedback: e.feedback))
        }
        try? context.save(); markChanged()
    }

    // MARK: Struct ↔ record mapping

    private static func apply(_ p: UserProfile, onboardingComplete: Bool, to r: ProfileRecord) {
        r.name = p.name
        r.goals = p.goals
        r.latitude = p.coordinates?.lat
        r.longitude = p.coordinates?.lon
        r.onboardingComplete = onboardingComplete
    }

    private static func apply(_ w: WeeklyStructure, to r: WeeklyStructureRecord) {
        r.maxHours = w.maxHours
        r.preferredRestDay = w.preferredRestDay
        r.longRunDay = w.longRunDay
        r.longRideDay = w.longRideDay
        r.sportRatio = stringKeyed(w.sportRatio)
        r.sportFloors = stringKeyed(w.sportFloors)
    }

    private static func apply(_ p: AthletePreferences, to r: PreferencesRecord) {
        r.noSwimDays = p.noSwimDays
        r.noBikeDays = p.noBikeDays
        r.noRunDays = p.noRunDays
        r.morningWorkouts = p.morningWorkouts
        r.indoorTrainerAvailable = p.indoorTrainerAvailable
    }

    private static func apply(_ p: SportProgress, to r: SportProgressRecord) {
        r.currentLevel = p.currentLevel
        r.abilities = p.abilities
        r.limitations = p.limitations
        r.injuriesAffecting = p.injuriesAffecting
        r.currentFocus = p.currentFocus
        r.maxContinuous = p.maxContinuous
        r.equipment = p.equipment
        r.notes = p.notes
    }

    private static func make(from r: SportProgressRecord) -> SportProgress {
        var p = SportProgress()
        p.currentLevel = r.currentLevel
        p.abilities = r.abilities
        p.limitations = r.limitations
        p.injuriesAffecting = r.injuriesAffecting
        p.currentFocus = r.currentFocus
        p.maxContinuous = r.maxContinuous
        p.equipment = r.equipment
        p.notes = r.notes
        return p
    }

    private static func familyMap(_ d: [String: Double]) -> [SportFamily: Double] {
        var out: [SportFamily: Double] = [:]
        for (k, v) in d { if let fam = SportFamily(rawValue: k.lowercased()) { out[fam] = v } }
        return out
    }
    private static func stringKeyed(_ m: [SportFamily: Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: m.map { ($0.key.rawValue, $0.value) })
    }
}
