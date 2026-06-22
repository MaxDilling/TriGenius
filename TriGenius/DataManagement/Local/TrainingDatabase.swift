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
// GOAL.md step 1+2: a persistent local store for historical activity data and
// the single source of truth the coach reads activities from.
//
// The primary purpose is fast local access to the daily training load
// (Garmin's `activityTrainingLoad`, the EPOC-based TSS-equivalent), which the
// later PMC engine (CTL / ATL / TSB) consumes. The full coach-facing record is
// also stored verbatim (`detailsJSON`) so `get_activities` can serve rich data
// without hitting the network mid-conversation.
//
// This is intentionally independent of `coach_memory.json`: the coach memory
// stays the LLM prompt context, while this database is the structured,
// queryable history.

// MARK: - SwiftData model

/// One stored activity. Keyed by a source-qualified id (e.g. "garmin:12345",
/// "healthkit:<uuid>") so repeated syncs upsert instead of duplicating.
@Model
final class ActivityRecord {
    @Attribute(.unique) var id: String
    /// Origin of the record ("garmin", "healthkit").
    var source: String
    /// Start-of-day date the activity belongs to (local), used for daily buckets.
    var date: Date
    /// Sport key as reported by the source (e.g. "running", "lap_swimming", "Cycling").
    var sport: String
    var name: String
    var durationMinutes: Double
    var distanceKm: Double
    /// TSS — the Training Stress Score driving the PMC. Currently sourced from
    /// Garmin's `activityTrainingLoad`; later computed natively (see `TSS`).
    /// Nil when the source did not report it (e.g. HealthKit).
    var tss: Double?
    var aerobicTE: Double?
    var anaerobicTE: Double?
    /// The full coach-facing record, JSON-encoded, served verbatim by `get_activities`.
    var detailsJSON: String

    init(
        id: String,
        source: String,
        date: Date,
        sport: String,
        name: String,
        durationMinutes: Double,
        distanceKm: Double,
        tss: Double?,
        aerobicTE: Double?,
        anaerobicTE: Double?,
        detailsJSON: String
    ) {
        self.id = id
        self.source = source
        self.date = date
        self.sport = sport
        self.name = name
        self.durationMinutes = durationMinutes
        self.distanceKm = distanceKm
        self.tss = tss
        self.aerobicTE = aerobicTE
        self.anaerobicTE = anaerobicTE
        self.detailsJSON = detailsJSON
    }
}

// MARK: - Performance metric model
//
// FEATURES.md "Performance data in the database (with history)": performance
// values (FTP, CSS, lactate thresholds, VO2max, …) used to live in
// `coach_memory.json` as overwrite-in-place scalars. They are now stored here as
// a timestamped, append-only time series — the same way Garmin tracks them — so
// the progression over time can be charted and the coach reads the latest value
// per metric from the DB instead of the JSON.

/// One performance value at a point in time. Keyed by a composite
/// "<metricKey>:<source>:<yyyy-MM-dd>" id so repeated same-day syncs upsert
/// instead of duplicating, while different days append to the series.
@Model
final class PerformanceMetricRecord {
    @Attribute(.unique) var id: String
    /// snake_case metric key, e.g. "cycling_ftp", "swim_css_pace".
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

// MARK: - Scheduled workout model
//
// FEATURES.md "Future / scheduled workouts in the Agenda" + "Training calendar
// screen" + "Drag-and-drop workout reschedule": a local store of PLANNED
// workouts (target sport / duration / TSS on a future date), distinct from the
// completed `ActivityRecord`s. Source-agnostic: populated from Garmin's calendar
// (`get_calendar`) and from the coach's own scheduling tools (`add_workout`).
// The dashboard Agenda, the calendar screen and the weekly targets all read it.

/// One planned workout. Keyed by a source-qualified id ("garmin:<workoutId>",
/// "local:<uuid>") so repeated calendar syncs upsert instead of duplicating.
@Model
final class ScheduledWorkoutRecord {
    @Attribute(.unique) var id: String
    /// Origin of the record ("garmin", "local").
    var source: String
    /// Start-of-day the workout is planned for (local).
    var date: Date
    /// Sport key (e.g. "running", "cycling", "lap_swimming").
    var sport: String
    var name: String
    /// Planned duration in minutes (0 when the source didn't specify one).
    var targetDurationMinutes: Double
    /// Planned TSS, when known. Nil → estimated from duration at read time.
    var targetTSS: Double?
    /// Optional free-text description of the planned session.
    var notes: String
    /// Local-only planned start time as minutes after midnight (e.g. 420 = 07:00).
    /// Nil → no specific time-of-day. Stored day-independent so a day-move keeps
    /// the time-of-day. Set by dragging onto a calendar segment; lost if the
    /// workout is (re)created in Garmin.
    var startMinute: Int?
    /// The completed activity Garmin linked to this plan (its `activityId`), set
    /// once the session is done. Used to suppress the now-redundant pending plan.
    /// Nil while still outstanding.
    var associatedActivityId: String?

    init(
        id: String,
        source: String,
        date: Date,
        sport: String,
        name: String,
        targetDurationMinutes: Double,
        targetTSS: Double?,
        notes: String = "",
        startMinute: Int? = nil,
        associatedActivityId: String? = nil
    ) {
        self.id = id
        self.source = source
        self.date = date
        self.sport = sport
        self.name = name
        self.targetDurationMinutes = targetDurationMinutes
        self.targetTSS = targetTSS
        self.notes = notes
        self.startMinute = startMinute
        self.associatedActivityId = associatedActivityId
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
    let distanceKm: Double
    let tss: Double?
    let aerobicTE: Double?
    let anaerobicTE: Double?
    let detailsJSON: String
}

/// Sendable snapshot used to hand planned workouts from the (non-MainActor)
/// data sources to the MainActor-bound store. `date` is normalized to
/// start-of-day on ingest.
struct IngestedScheduledWorkout: Sendable {
    let id: String
    let source: String
    let date: Date
    let sport: String
    let name: String
    let targetDurationMinutes: Double
    let targetTSS: Double?
    let notes: String
    var associatedActivityId: String? = nil
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
/// system-prompt context and the Settings display. Replaces the former
/// `coach_memory.json` scalars.
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
            container = try ModelContainer(for: ActivityRecord.self, PerformanceMetricRecord.self, ScheduledWorkoutRecord.self)
        } catch {
            // An in-memory fallback keeps the app usable even if the on-disk
            // store can't be opened (e.g. an incompatible migration).
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: ActivityRecord.self, PerformanceMetricRecord.self, ScheduledWorkoutRecord.self, configurations: config)
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

    /// Delete every stored record — activities, performance metrics and
    /// scheduled workouts. The `coach_memory.json` profile/settings are NOT
    /// touched; this only clears the local time-series database.
    func deleteAllData() {
        try? context.delete(model: ActivityRecord.self)
        try? context.delete(model: PerformanceMetricRecord.self)
        try? context.delete(model: ScheduledWorkoutRecord.self)
        try? context.save()
        markChanged()
    }

    /// Upsert a batch of activities (insert new, update existing by id).
    func ingest(_ activities: [IngestedActivity]) {
        guard !activities.isEmpty else { return }
        for a in activities {
            let id = a.id
            let existing = try? context.fetch(
                FetchDescriptor<ActivityRecord>(predicate: #Predicate { $0.id == id })
            ).first
            if let record = existing {
                record.source = a.source
                record.date = a.date
                record.sport = a.sport
                record.name = a.name
                record.durationMinutes = a.durationMinutes
                record.distanceKm = a.distanceKm
                record.tss = a.tss
                record.aerobicTE = a.aerobicTE
                record.anaerobicTE = a.anaerobicTE
                record.detailsJSON = a.detailsJSON
            } else {
                context.insert(ActivityRecord(
                    id: a.id,
                    source: a.source,
                    date: a.date,
                    sport: a.sport,
                    name: a.name,
                    durationMinutes: a.durationMinutes,
                    distanceKm: a.distanceKm,
                    tss: a.tss,
                    aerobicTE: a.aerobicTE,
                    anaerobicTE: a.anaerobicTE,
                    detailsJSON: a.detailsJSON
                ))
            }
        }
        try? context.save()
        markChanged()
    }

    /// Delete `source`-originated activities on/after `from` whose id is not in
    /// `keep`. Used to reconcile the Apple Health import after dropping
    /// Garmin-mirrored workouts at the source: stale duplicates already stored
    /// from earlier syncs are removed, while activities from other sources and
    /// the freshly-fetched ones are untouched.
    func pruneActivities(source: String, from: Date, keeping keep: Set<String>) {
        let stale = (try? context.fetch(
            FetchDescriptor<ActivityRecord>(
                predicate: #Predicate { $0.source == source && $0.date >= from }
            )
        ))?.filter { !keep.contains($0.id) } ?? []
        guard !stale.isEmpty else { return }
        for r in stale { context.delete(r) }
        try? context.save()
        markChanged()
    }

    /// Activities on/after `since` (or all), newest first.
    func activities(since: Date? = nil) -> [ActivityRecord] {
        var descriptor = FetchDescriptor<ActivityRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        if let since {
            descriptor.predicate = #Predicate { $0.date >= since }
        }
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Activities within `[from, to]` (start-of-day inclusive), newest first —
    /// for the calendar, which needs the sessions per day, not just a flag.
    func activities(from: Date, to: Date) -> [ActivityRecord] {
        let cal = Calendar.current
        let lo = cal.startOfDay(for: from)
        let hi = cal.startOfDay(for: to)
        let descriptor = FetchDescriptor<ActivityRecord>(
            predicate: #Predicate { $0.date >= lo && $0.date <= hi },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Total number of stored activities.
    var count: Int {
        (try? context.fetchCount(FetchDescriptor<ActivityRecord>())) ?? 0
    }

    /// Daily total TSS over `[from, to]`, ascending — input for the PMC engine.
    func dailyTSS(from: Date, to: Date) -> [DailyTSS] {
        let descriptor = FetchDescriptor<ActivityRecord>(
            predicate: #Predicate { $0.date >= from && $0.date <= to },
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

    // MARK: - Scheduled workouts

    /// Upsert a batch of planned workouts (insert new, update existing by id).
    /// Dates are normalized to start-of-day so they bucket per calendar day.
    func ingestScheduled(_ workouts: [IngestedScheduledWorkout]) {
        guard !workouts.isEmpty else { return }
        let cal = Calendar.current
        for w in workouts {
            let id = w.id
            let day = cal.startOfDay(for: w.date)
            let existing = try? context.fetch(
                FetchDescriptor<ScheduledWorkoutRecord>(predicate: #Predicate { $0.id == id })
            ).first
            if let record = existing {
                record.source = w.source
                record.date = day
                record.sport = w.sport
                record.name = w.name
                record.targetDurationMinutes = w.targetDurationMinutes
                record.targetTSS = w.targetTSS
                record.notes = w.notes
                record.associatedActivityId = w.associatedActivityId
            } else {
                context.insert(ScheduledWorkoutRecord(
                    id: w.id, source: w.source, date: day, sport: w.sport, name: w.name,
                    targetDurationMinutes: w.targetDurationMinutes, targetTSS: w.targetTSS, notes: w.notes,
                    associatedActivityId: w.associatedActivityId
                ))
            }
        }
        try? context.save()
        markChanged()
    }

    /// Planned workouts in `[from, to]` that are still outstanding — Garmin hasn't
    /// linked them to a completed activity we've already stored. Centralizes the
    /// plan/activity de-duplication so the Agenda, calendar and projections all hide
    /// a plan the moment its completion lands, instead of showing it twice.
    func openScheduledWorkouts(from: Date, to: Date) -> [ScheduledWorkoutRecord] {
        let planned = scheduledWorkouts(from: from, to: to)
        guard planned.contains(where: { $0.associatedActivityId != nil }) else { return planned }
        let done = Set(activities(from: from, to: to).map(\.id))
        return planned.filter { p in
            guard let aid = p.associatedActivityId else { return true }
            return !done.contains("garmin:\(aid)")
        }
    }

    /// Planned workouts within `[from, to]` (start-of-day inclusive), ascending.
    func scheduledWorkouts(from: Date, to: Date) -> [ScheduledWorkoutRecord] {
        let cal = Calendar.current
        let lo = cal.startOfDay(for: from)
        let hi = cal.startOfDay(for: to)
        let descriptor = FetchDescriptor<ScheduledWorkoutRecord>(
            predicate: #Predicate { $0.date >= lo && $0.date <= hi },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Reschedule a planned workout to a new day. Returns the updated record.
    @discardableResult
    func moveScheduledWorkout(id: String, to newDate: Date) -> ScheduledWorkoutRecord? {
        let record = try? context.fetch(
            FetchDescriptor<ScheduledWorkoutRecord>(predicate: #Predicate { $0.id == id })
        ).first
        guard let record else { return nil }
        record.date = Calendar.current.startOfDay(for: newDate)
        try? context.save()
        markChanged()
        return record
    }

    /// Update a planned workout's content in place (date is left untouched —
    /// use `moveScheduledWorkout` for that). Only non-nil arguments are applied;
    /// `targetTSS` is double-optional so `.some(nil)` can explicitly clear it
    /// while `nil` leaves it unchanged. Returns the updated record.
    @discardableResult
    func updateScheduledContent(id: String, sport: String? = nil, name: String? = nil,
                                targetDurationMinutes: Double? = nil, targetTSS: Double?? = nil,
                                notes: String? = nil) -> ScheduledWorkoutRecord? {
        let record = try? context.fetch(
            FetchDescriptor<ScheduledWorkoutRecord>(predicate: #Predicate { $0.id == id })
        ).first
        guard let record else { return nil }
        if let sport { record.sport = sport }
        if let name { record.name = name }
        if let targetDurationMinutes { record.targetDurationMinutes = targetDurationMinutes }
        if let targetTSS { record.targetTSS = targetTSS }
        if let notes { record.notes = notes }
        try? context.save()
        markChanged()
        return record
    }

    /// Set (or clear) a planned workout's local time-of-day, in minutes after
    /// midnight. Used when dragging a workout onto a calendar segment. Returns
    /// the updated record.
    @discardableResult
    func setScheduledStartMinute(id: String, minute: Int?) -> ScheduledWorkoutRecord? {
        let record = try? context.fetch(
            FetchDescriptor<ScheduledWorkoutRecord>(predicate: #Predicate { $0.id == id })
        ).first
        guard let record else { return nil }
        record.startMinute = minute
        try? context.save()
        markChanged()
        return record
    }

    /// Remove a planned workout by id.
    func deleteScheduledWorkout(id: String) {
        guard let record = try? context.fetch(
            FetchDescriptor<ScheduledWorkoutRecord>(predicate: #Predicate { $0.id == id })
        ).first else { return }
        context.delete(record)
        try? context.save()
        markChanged()
    }

    /// Replace all `source`-originated planned workouts within `[from, to]` with
    /// a fresh batch — used when re-syncing the Garmin calendar so deletions on
    /// the device are reflected locally. Locally-created workouts are untouched.
    func replaceScheduled(source: String, from: Date, to: Date, with workouts: [IngestedScheduledWorkout]) {
        let cal = Calendar.current
        let lo = cal.startOfDay(for: from)
        let hi = cal.startOfDay(for: to)
        let stale = (try? context.fetch(
            FetchDescriptor<ScheduledWorkoutRecord>(
                predicate: #Predicate { $0.source == source && $0.date >= lo && $0.date <= hi }
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
                FetchDescriptor<ScheduledWorkoutRecord>(predicate: #Predicate { $0.id == id })
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

    /// Latest value per metric key — the source for the coach's prompt context
    /// and the Settings display. Newest date wins; ties break by source rank.
    func latestSnapshot() -> PerformanceSnapshot {
        let records = (try? context.fetch(FetchDescriptor<PerformanceMetricRecord>())) ?? []
        var latest: [String: PerformanceMetricRecord] = [:]
        for r in records {
            if let cur = latest[r.metricKey] {
                let better = r.date > cur.date ||
                    (r.date == cur.date && Self.sourceRank(r.source) > Self.sourceRank(cur.source))
                if better { latest[r.metricKey] = r }
            } else {
                latest[r.metricKey] = r
            }
        }
        var snap = PerformanceSnapshot()
        snap.cyclingFTP = latest["cycling_ftp"].map { Int($0.value.rounded()) }
        snap.runningFTP = latest["running_ftp"].map { Int($0.value.rounded()) }
        snap.cssPaceSeconds = latest["swim_css_pace"]?.value
        snap.lactateThrHR = latest["lactate_threshold_hr"].map { Int($0.value.rounded()) }
        snap.maxHR = latest["max_hr"].map { Int($0.value.rounded()) }
        snap.lactateThrPaceSeconds = latest["lactate_threshold_pace"]?.value
        snap.vo2maxRunning = latest["vo2max_running"]?.value
        snap.vo2maxCycling = latest["vo2max_cycling"]?.value
        snap.weightKg = latest["weight_kg"]?.value
        return snap
    }

    /// Ascending day-by-day history for one metric key — the progression the
    /// Performance Insights charts plot. When several sources report the same
    /// day, the higher-ranked source wins (matching `latestSnapshot`).
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
