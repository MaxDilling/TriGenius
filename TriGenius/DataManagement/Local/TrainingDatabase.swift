import Foundation
import OSLog
import SwiftData
import CoreData

extension Notification.Name {
    /// Posted (on the main actor) whenever the local training store is mutated —
    /// activities, performance metrics or scheduled workouts, from any path
    /// (coach tools, a sync, or a user action). Views that render from a cached
    /// snapshot (Dashboard, Calendar, Statistics) observe this to reload
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
    /// The *effective* date every reader consumes: the planned day while the row is
    /// an open plan, the actual start day once completed — a plan done a day early
    /// or late shows (and load-counts) on the day it was actually done. The planned
    /// slot survives separately in `plannedDate`.
    var date: Date = Date.distantPast
    /// Sport key (e.g. "running", "lap_swimming", "Cycling").
    var sport: String = ""
    var name: String = ""
    /// Per-write-target external ids, JSON-encoded: `{"garmin":"123","appleWatch":"<uuid>"}`.
    /// Lets a write-target switch re-push a plan that the new target hasn't seen,
    /// without losing the original.
    var externalRefsJSON: String = "{}"
    /// Local clock start time as minutes after midnight (e.g. 630 = 10:30). Same
    /// effective semantics as `date`: the planned time-of-day while open (set from
    /// the source's `"time"` field once completed). Nil → no specific time-of-day
    /// (kept in the all-day band).
    var startMinute: Int?
    /// Athlete edits layered over the source data, JSON-encoded (e.g.
    /// `manual_distance_m`, `feel`, `rpe`, `notes`). The durable authority for
    /// manual corrections: re-applied onto the completed section after every
    /// source write (`applyOverrides`), so a resync can rewrite `detailsJSON`
    /// blindly without losing them. "{}" when the athlete changed nothing.
    var overridesJSON: String = "{}"

    // MARK: Planned section (present when `isPlanned`)

    /// The day the workout was planned for — owned by the plan, never touched by a
    /// completion. Backs `unfold` (reopening a plan returns it to its slot) and
    /// keeps calendar sync from dragging a folded row back to the planned day.
    var plannedDate: Date?
    /// Planned time-of-day (minutes after midnight), same lifecycle as `plannedDate`.
    var plannedStartMinute: Int?
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
    /// The full activity record, JSON-encoded — the rich blob the detail UI reads
    /// and the coach's lean `get_workouts` projection is derived from. "" when this
    /// row has no completed activity yet.
    var detailsJSON: String = ""
    /// Max-mean power per grid duration, computed at ingest from the source's raw
    /// power stream (`PowerCurve.encode`). "" when the activity has no power stream.
    var powerCurveJSON: String = ""
    /// Best *steady* 20-minute mean HR in this activity (`LTHREstimate.steadyWindow`),
    /// 0 when none qualified. Stored raw and unfiltered: rejection against HRmax
    /// happens at read time, so correcting a wrong HRmax re-filters the whole history
    /// without re-ingesting it.
    var steadyHR20: Double = 0
    /// This activity's peak HR, the input to that rejection.
    var peakHR: Double = 0
    /// Best mean power per duration paired with the heart rate held across those same
    /// seconds (`VO2maxEstimate.profile`), "" for anything without both streams. Stored
    /// raw for the same reason as `steadyHR20`: the reconstruction needs HRmax, HRrest
    /// and mass, so keeping the pair lets a corrected input re-resolve history.
    var submaxProfileJSON: String = ""
    /// Heart rate → best grade-adjusted speed for this run (`LTPaceEstimate.profile`),
    /// "" for anything that isn't a run with both streams. Stored instead of a finished
    /// MAS for the same reason as `steadyHR20`: the reconstruction needs HRmax and
    /// HRrest, and keeping the raw profile lets a corrected HRmax re-resolve history.
    var paceHRProfileJSON: String = ""
    /// Downsampled metric streams (`WorkoutStreams.encode`), the detail charts'
    /// data. Empty when the source delivered no streams for this activity.
    var streamsData: Data = Data()
    /// Value→seconds zone distribution (`ZoneHistogram`), kept so a threshold change
    /// re-buckets time-in-zone exactly without re-fetching the raw stream. Empty for
    /// a multisport row — its legs carry their own.
    var zoneHistogramData: Data = Data()
    /// The legs of a multisport session (`WorkoutSegments.encode`), "" for a
    /// single-sport row. When present, `tss` and `distanceKm` are the sum over
    /// these and every per-sport reader goes through `sportContributions`.
    var segmentsJSON: String = ""

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
        detailsJSON: String = "",
        powerCurveJSON: String = "",
        steadyHR20: Double = 0,
        peakHR: Double = 0,
        paceHRProfileJSON: String = "",
        submaxProfileJSON: String = "",
        streamsData: Data = Data(),
        zoneHistogramData: Data = Data(),
        segmentsJSON: String = ""
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
        self.detailsJSON = detailsJSON
        self.powerCurveJSON = powerCurveJSON
        self.steadyHR20 = steadyHR20
        self.peakHR = peakHR
        self.paceHRProfileJSON = paceHRProfileJSON
        self.submaxProfileJSON = submaxProfileJSON
        self.streamsData = streamsData
        self.zoneHistogramData = zoneHistogramData
        self.segmentsJSON = segmentsJSON
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
// by purpose. Shared by ingest, the Statistics UI and the
// "delete historical performance data" dev action so the sets never drift.
enum MetricKeys {
    /// Physiological capacity markers (FTP, VO2max, thresholds, zones, weight).
    /// Speeds are stored as raw m/s under `*_speed` keys (not pace-seconds); the
    /// pace conversion happens only when building `PerformanceSnapshot` / the UI.
    static let performance: Set<String> = {
        var keys: Set<String> = [
            "cycling_ftp", "running_ftp",
            "vo2max_running", "vo2max_cycling",
            "lactate_threshold_hr", "lactate_threshold_hr_cycling", "lactate_threshold_speed",
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
    /// Normalized, *unscored* activity JSON. The store computes TSS + the resolved
    /// distance from this at ingest (see `TrainingDataStore.ingest`).
    let detailsJSON: String
    /// Encoded max-mean power curve (`PowerCurve.encode`), "" when the source has
    /// no power stream for this activity.
    let powerCurveJSON: String
    /// Downsampled metric streams (`WorkoutStreams.encode`), empty when the source
    /// delivered none.
    let streamsData: Data
    /// Multisport legs (`WorkoutSegments.encode`), "" for a single-sport activity.
    /// Also *unscored* — the store scores each leg and sums at ingest.
    let segmentsJSON: String
    /// Full-resolution stream input for time-in-zone. Transient: bucketed into the
    /// details at ingest (`ZoneBucketing`) against the thresholds of the activity's
    /// own date, then dropped — only the bucketed seconds are stored. Split the same
    /// way the details are, so each scored unit gets its own streams: this activity's
    /// own, and one entry per multisport leg keyed by that leg's `sourceId`.
    let zoneSamples: ZoneSamples
    let legZoneSamples: [String: ZoneSamples]
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
nonisolated struct MetricPoint: Sendable, Identifiable {
    let date: Date
    let value: Double
    /// True when the value was derived (`FTPEstimate`/`LTHREstimate`) instead of
    /// reported by a source. Nothing writes an estimate into the metric series, so
    /// such a point exists only by re-resolution (`PerformanceHistory.estimatedSeries`)
    /// — and every reader has to mark it as the estimate it is.
    var isEstimated: Bool = false
    /// What the estimate behind this point rests on, when it is one. Nil for a stored
    /// reading, which is a measurement and carries no confidence.
    var confidence: EstimateConfidence?
    /// Whether the point has to be read as provisional: carried forward with no current
    /// evidence, or resting on a window too thin for the aggregate to be a robust one.
    /// Drawn dashed — a solid line makes either of those read as a measurement.
    var isProvisional: Bool { confidence != nil && confidence != .anchored }
    var id: Date { date }

    /// One drawable stretch of a series: consecutive points that share a styling.
    struct Stretch: Identifiable, Sendable {
        let id: Int
        let isProvisional: Bool
        var points: [MetricPoint]
    }

    /// Collapse daily wellness points into one mean per calendar week, labelled by the
    /// week's start day — the trend of a signal whose day-to-day noise swamps a
    /// first-to-last change.
    static func weeklyMeans(_ points: [MetricPoint]) -> [MetricPoint] {
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

    /// The mean of the trailing `days` at every point of a date-ordered series — the
    /// trend of a signal whose day-to-day noise swamps a first-to-last change. Dated
    /// like the points themselves, so the line spans exactly the readings it smooths.
    static func rollingMeans(_ points: [MetricPoint], days: Int = 7) -> [MetricPoint] {
        let window = Double(days) * 86_400
        var start = 0
        var sum = 0.0
        return points.indices.map { i in
            sum += points[i].value
            while points[i].date.timeIntervalSince(points[start].date) >= window {
                sum -= points[start].value
                start += 1
            }
            return MetricPoint(date: points[i].date, value: sum / Double(i - start + 1))
        }
    }

    /// Cut a series into stretches a chart can draw as separate lines.
    ///
    /// Needed because `lineStyle` in Swift Charts applies to a whole *series*: styling
    /// each point individually makes one of them style the entire line, which drew a
    /// three-month window fully dashed and a six-month one fully solid off the same
    /// data. Each stretch becomes its own series instead.
    ///
    /// An edge counts as provisional when **either** end is, so the approach to a
    /// carried value and the return from it are both drawn as what they are; that also
    /// makes consecutive stretches share their boundary point and meet on the page.
    static func stretches(_ points: [MetricPoint]) -> [Stretch] {
        guard points.count > 1 else { return [] }
        var out: [Stretch] = []
        for i in 0 ..< points.count - 1 {
            let provisional = points[i].isProvisional || points[i + 1].isProvisional
            if out.last?.isProvisional == provisional {
                out[out.count - 1].points.append(points[i + 1])
            } else {
                out.append(Stretch(id: out.count, isProvisional: provisional,
                                   points: [points[i], points[i + 1]]))
            }
        }
        return out
    }
}

/// Latest value per performance metric, read from the DB to build the coach's
/// system-prompt context and the Settings display.
nonisolated struct PerformanceSnapshot: Sendable {
    var cyclingFTP: Int?
    /// True when `cyclingFTP` was derived from VO2max + mass (`FTPEstimate`) rather
    /// than measured. Rendered wherever the value is shown so an estimate is never
    /// read as a measurement.
    var cyclingFTPIsEstimated: Bool = false
    var runningFTP: Int?
    /// Swim critical-swim-speed pace, in seconds per 100 m.
    var cssPaceSeconds: Double?
    /// **Running** lactate-threshold HR — the value a watch publishes, and the one that
    /// stands for every discipline that has nothing of its own. Read through
    /// `thresholdHR(for:)`, never directly, wherever a sport is known.
    var lactateThrHR: Int?
    /// True when `lactateThrHR` was derived (`LTHREstimate`) rather than measured.
    var lactateThrHRIsEstimated: Bool = false
    /// What the estimate rests on — how many qualifying efforts, and how recent.
    /// `.rough` means the HRmax fraction alone, with nothing the athlete did behind it.
    var lactateThrHRConfidence: EstimateConfidence = .rough
    /// Cycling lactate-threshold HR, reconstructed from power-gated rides. Nil until
    /// enough ride evidence exists; `thresholdHR(for:)` then answers with the running
    /// value, which is what the athlete has on record.
    var cyclingLactateThrHR: Int?
    var cyclingLactateThrHRIsEstimated: Bool = false
    var cyclingLactateThrHRConfidence: EstimateConfidence = .rough
    /// Maximum heart rate, in bpm.
    var maxHR: Int?
    /// Running lactate-threshold pace, in seconds per km.
    var lactateThrPaceSeconds: Double?
    /// True when `lactateThrPaceSeconds` was reconstructed from ordinary runs
    /// (`LTPaceEstimate`) rather than reported by a source.
    var lactateThrPaceIsEstimated: Bool = false
    /// Whether that reconstruction answered from the current window or is carrying an
    /// older one forward. For a low-volume runner the latter is the common case.
    var lactateThrPaceConfidence: EstimateConfidence = .rough
    /// The share of reconstructed MAS the estimate used — the athlete's own setting, or
    /// what their LTHR implies. Surfaced so the UI shows the value actually applied
    /// rather than re-deriving it and drifting from the resolver.
    var ltPaceFractionUsed: Double?
    var vo2maxRunning: Double?
    /// True when `vo2maxRunning` was reconstructed from ordinary runs — the same MAS
    /// `lactateThrPaceSeconds` rests on, under the ACSM running economy equation.
    var vo2maxRunningIsEstimated: Bool = false
    var vo2maxRunningConfidence: EstimateConfidence = .rough
    var vo2maxCycling: Double?
    /// True when `vo2maxCycling` was reconstructed from submaximal rides
    /// (`VO2maxEstimate`) rather than reported by a source.
    var vo2maxCyclingIsEstimated: Bool = false
    var weightKg: Double?

    /// The lactate-threshold HR that applies to one discipline.
    ///
    /// Two values, not one: cycling LTHR runs 5–10 bpm under running LTHR in the same
    /// athlete, so scoring a ride against the running value reads the ride as easier
    /// than it was and draws its heart-rate zones on bounds it never trained in.
    ///
    /// With no ride evidence the bike falls back to **the lower of** the athlete's
    /// running LTHR and `LTHREstimate.fractionOfHRMax`. The running value alone is not
    /// the safer half of that pair, which is the trap: it is measured, but it measures a
    /// different quantity, and how far above cycling it sits is itself athlete-specific
    /// — the two reference athletes hold 0.863 and 0.910 of HRmax at running threshold
    /// against 0.830 and 0.816 at cycling, so using it read 6.9 and **19.1 bpm** high.
    /// The bound cuts that to 4.2 and 6.9 while adding the constraint that has to hold
    /// physiologically: the bike threshold cannot sit above the run threshold.
    ///
    /// Still a stand-in that reads a few bpm high on both, so rides scored on heart rate
    /// come out slightly low until a hard ride exists. Dropping to nil instead would
    /// remove their training load entirely, which is worse.
    func thresholdHR(for family: SportFamily) -> Int? {
        guard family == .bike else { return lactateThrHR }
        if let cyclingLactateThrHR { return cyclingLactateThrHR }
        guard let lactateThrHR else { return nil }
        guard let maxHR, maxHR > 0 else { return lactateThrHR }
        return min(lactateThrHR, Int((LTHREstimate.fractionOfHRMax * Double(maxHR)).rounded()))
    }

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
nonisolated struct PerformanceHistory: Sendable {
    /// One dated metric reading, pre-ranked by source so ties resolve the same way
    /// `latestSnapshot` does.
    struct Entry: Sendable {
        let date: Date
        let value: Double
        let rank: Int
    }

    /// `sourceRank` of a hand-entered reading — the tier an estimate must not replace.
    static let manualRank = 3

    /// One activity's threshold evidence: the sustained-HR window `LTHREstimate`
    /// reads and the pace/HR profile `LTPaceEstimate` reads. Both estimates resolve
    /// from the same fetch — materializing every stored stream blob twice would be
    /// the expensive part.
    struct ActivityEvidence: Sendable {
        let date: Date
        let steadyHR20: Double
        let peakHR: Double
        var paceProfile: [Int: Double] = [:]
        /// Duration → (best mean power, concurrent mean HR). Empty without power.
        var submaxProfile: [Int: (watts: Double, hr: Double)] = [:]
        /// Which sport's threshold this effort can speak to. LTHR differs by 5-10 bpm
        /// between running and cycling in the same athlete, so pooling them reads a ride
        /// as a run.
        var family: SportFamily? = nil
    }

    /// metricKey → readings, ascending by date.
    private let byKey: [String: [Entry]]
    /// Carried on the resolver so every consumer of `snapshot(asOf:)` sees the same
    /// answer. Both are opt-ins: an estimate replaces the source's value only when
    /// the athlete asked for it.
    private let estimateVO2maxFromRides: Bool
    private let estimateFTPFromVO2max: Bool
    private let estimateLTHRFromHRMax: Bool
    private let estimateLTPaceFromRuns: Bool
    private let estimateRunningVO2maxFromRuns: Bool
    private let estimateCyclingLTHRFromRides: Bool
    /// The share of reconstructed MAS held at threshold, in force for **every** date —
    /// the athlete's own measurement (`ltPaceFractionOverride`) or what their resolved
    /// LTHR implies.
    ///
    /// An athlete constant, so it is resolved once from the values standing now rather
    /// than re-derived per date. Deriving it per date puts the LTHR series' own
    /// trajectory into the *shape* of the pace series, where only its scale belongs:
    /// on a real season this athlete's LTHR moved 176 → 184 → 182 bpm, which is 6.8 %
    /// of fraction and ~20 s/km of pure artifact, in a curve whose whole purpose is
    /// to show how the pace itself moved.
    private var ltPaceFraction: Double?
    private let evidence: [ActivityEvidence]

    init(byKey: [String: [Entry]], estimateFTPFromVO2max: Bool,
         estimateVO2maxFromRides: Bool = false,
         estimateLTHRFromHRMax: Bool = false, estimateLTPaceFromRuns: Bool = false,
         estimateRunningVO2maxFromRuns: Bool = false,
         estimateCyclingLTHRFromRides: Bool = false,
         /// The athlete's own %HRR-at-threshold ÷ pool inflation, when they measured it
         /// in a threshold test. Nil derives the fraction from the resolved LTHR.
         ltPaceFractionOverride: Double? = nil,
         evidence: [ActivityEvidence] = []) {
        self.byKey = byKey.mapValues { $0.sorted { $0.date < $1.date } }
        self.estimateFTPFromVO2max = estimateFTPFromVO2max
        self.estimateVO2maxFromRides = estimateVO2maxFromRides
        self.estimateLTHRFromHRMax = estimateLTHRFromHRMax
        self.estimateLTPaceFromRuns = estimateLTPaceFromRuns
        self.estimateRunningVO2maxFromRuns = estimateRunningVO2maxFromRuns
        self.estimateCyclingLTHRFromRides = estimateCyclingLTHRFromRides
        self.evidence = evidence.sorted { $0.date < $1.date }
        guard estimateLTPaceFromRuns else { return }
        if let ltPaceFractionOverride {
            ltPaceFraction = ltPaceFractionOverride
            return
        }
        let now = Date()
        // The resolved LTHR, so the fraction matches the threshold HR the athlete is
        // shown rather than whichever reading happens to be stored.
        guard let lthr = snapshot(asOf: now, resolving: ["lactate_threshold_hr"]).lactateThrHR,
              let hrMax = value("max_hr", asOf: now), let hrRest = restingHR(asOf: now)
        else { return }
        ltPaceFraction = LTPaceEstimate.fractionOfMAS(lthr: Double(lthr), hrRest: hrRest,
                                                      hrMax: hrMax)
    }

    /// The reading of one metric as it stood on `date`: the newest on or before
    /// `date`, ties broken by source rank. Nil when none exists yet by then.
    private func entry(_ key: String, asOf date: Date) -> Entry? {
        guard let entries = byKey[key] else { return nil }
        var best: Entry?
        for e in entries where e.date <= date {
            guard let b = best else { best = e; continue }
            if e.date > b.date || (e.date == b.date && e.rank > b.rank) { best = e }
        }
        return best
    }

    private func value(_ key: String, asOf date: Date) -> Double? { entry(key, asOf: date)?.value }

    /// Days of resting-HR readings the heart-rate reserve is taken over.
    static let restingHRBaselineDays = 28.0

    /// Resting HR as a *baseline* rather than as one morning's reading.
    ///
    /// The reserve scales an aggregate built from three months of running, so a single
    /// day's value is the wrong quantity: submaximal heart rate fluctuates 2-8 bpm
    /// day to day (Achten & Jeukendrup 2003; Blagrove 2017) and this athlete's series
    /// spans 45-56 bpm, which is the sawtooth on the threshold-pace chart, not fitness.
    /// The median over the trailing window rejects the single bad night that a mean
    /// would carry. Falls back to the latest reading before the window has filled.
    private func restingHR(asOf date: Date) -> Double? {
        guard let entries = byKey["resting_hr"] else { return nil }
        let cutoff = date.addingTimeInterval(-Self.restingHRBaselineDays * 86_400)
        let window = entries.filter { $0.date > cutoff && $0.date <= date }.map(\.value).sorted()
        guard !window.isEmpty else { return value("resting_hr", asOf: date) }
        let mid = window.count / 2
        return window.count.isMultiple(of: 2) ? (window[mid - 1] + window[mid]) / 2 : window[mid]
    }

    /// A hand-entered reading is the athlete correcting the record, so an estimate
    /// never displaces it — unlike a synced one, which is what opting in is for.
    private func isManual(_ key: String, asOf date: Date) -> Bool {
        entry(key, asOf: date)?.rank == Self.manualRank
    }

    /// What each estimated key needs resolved ahead of it: FTP reads the resolved
    /// VO2max. Anything outside a key's set is work a caller asking for that one
    /// series never uses.
    private static let estimateDependencies: [String: Set<String>] = [
        "vo2max_cycling": ["vo2max_cycling"],
        "cycling_ftp": ["cycling_ftp", "vo2max_cycling"],
        "lactate_threshold_hr": ["lactate_threshold_hr"],
        "lactate_threshold_hr_cycling": ["lactate_threshold_hr_cycling"],
        "lactate_threshold_speed": ["lactate_threshold_speed"],
        "vo2max_running": ["vo2max_running"],
    ]

    /// The metric snapshot as it stood on `date`, assembled for the TSS engine.
    /// Pass `.distantFuture` to get the latest value of every metric.
    ///
    /// `resolving` narrows which estimates actually run; nil runs every one that is
    /// switched on, which is what the TSS engine needs. `estimatedSeries` passes a
    /// single key's dependencies instead — it evaluates this per date, and running the
    /// other three estimates on each of them was half the cost of drawing the charts.
    func snapshot(asOf date: Date, resolving: Set<String>? = nil) -> PerformanceSnapshot {
        func wanted(_ key: String) -> Bool { resolving?.contains(key) ?? true }
        var snap = PerformanceSnapshot()
        snap.cyclingFTP = value("cycling_ftp", asOf: date).map { Int($0.rounded()) }
        snap.runningFTP = value("running_ftp", asOf: date).map { Int($0.rounded()) }
        // CSS / LT thresholds are stored as raw speed (m/s); convert to the
        // pace-seconds the snapshot (and the TSS engine) consume.
        if let s = value("swim_css_speed", asOf: date), s > 0 { snap.cssPaceSeconds = 100.0 / s }
        snap.lactateThrHR = value("lactate_threshold_hr", asOf: date).map { Int($0.rounded()) }
        snap.cyclingLactateThrHR = value("lactate_threshold_hr_cycling", asOf: date).map { Int($0.rounded()) }
        snap.maxHR = value("max_hr", asOf: date).map { Int($0.rounded()) }
        if let s = value("lactate_threshold_speed", asOf: date), s > 0 { snap.lactateThrPaceSeconds = 1000.0 / s }
        snap.vo2maxRunning = value("vo2max_running", asOf: date)
        snap.vo2maxCycling = value("vo2max_cycling", asOf: date)
        snap.weightKg = value("weight_kg", asOf: date)
        // `.distantFuture` asks for the latest value, so every observation window has to
        // hang off today — not off a window ending in the year 4000.
        let anchor = min(date, .now)

        if estimateVO2maxFromRides, wanted("vo2max_cycling"), !isManual("vo2max_cycling", asOf: date),
           let hrMax = snap.maxHR, hrMax > 0,
           let hrRest = restingHR(asOf: date), hrRest > 0,
           let mass = snap.weightKg, mass > 0 {
            // A ride peaking above the athlete's own maximum has a misreading sensor,
            // and an HR that is wrong in either direction moves the reserve the whole
            // reconstruction scales by. Dropped whole, as on the other two paths.
            let efforts = evidence
                .filter { $0.family == .bike && $0.peakHR <= Double(hrMax) }
                .flatMap { o in
                o.submaxProfile.map {
                    VO2maxEstimate.Effort(date: o.date, seconds: $0.key,
                                          watts: $0.value.watts, heartRate: $0.value.hr)
                }
            }
            if let est = VO2maxEstimate.estimate(efforts: efforts, hrMax: Double(hrMax),
                                                 hrRest: hrRest, massKg: mass, asOf: anchor) {
                snap.vo2maxCycling = est.vo2max
                snap.vo2maxCyclingIsEstimated = true
            }
        }
        // Opting in *replaces* the synced source's value: the reason to enable this is
        // that the watch's own number is absent or stale, so preferring it would defeat
        // the setting. A manual reading outranks the estimate, or the athlete's own
        // correction would be unreachable. The source value still stands when the
        // estimate cannot be computed — a nil threshold silently drops TL scoring.
        // Both inputs resolve `asOf: date` like every other threshold, so a January
        // ride is scored against January's VO2max and mass.
        if estimateFTPFromVO2max, wanted("cycling_ftp"), !isManual("cycling_ftp", asOf: date),
           let watts = FTPEstimate.fromVO2max(snap.vo2maxCycling, massKg: snap.weightKg) {
            snap.cyclingFTP = Int(watts.rounded())
            snap.cyclingFTPIsEstimated = true
        }
        // Running LTHR specifically. Cycling LTHR runs 5-10 bpm lower in the same
        // athlete, so one pooled value would read a ride as a run — and this is the
        // value Garmin publishes and the HR zones are drawn against.
        if estimateLTHRFromHRMax, wanted("lactate_threshold_hr"), !isManual("lactate_threshold_hr", asOf: date),
           let hrMax = snap.maxHR, hrMax > 0 {
            let efforts = evidence
                .filter { $0.family == .run && $0.peakHR <= Double(hrMax) }
                .map { LTHREstimate.Effort(date: $0.date, steadyHR: $0.steadyHR20) }
            if let est = LTHREstimate.estimate(efforts: efforts, hrMax: Double(hrMax),
                                               gate: .heartRate, asOf: anchor) {
                snap.lactateThrHR = Int(est.bpm.rounded())
                snap.lactateThrHRIsEstimated = true
                snap.lactateThrHRConfidence = est.confidence
            }
        }
        // Cycling LTHR, from the power-gated rides. The gate is on watts and not on heart
        // rate because on a power sport the intensity is *measured*: one ride at 57 % of
        // this athlete's test power but 9 bpm higher heart rate had set his threshold
        // 11 bpm high under a heart-rate gate, having cleared every artifact filter.
        //
        // `.rough` is refused rather than published: with no qualifying ride the
        // population fraction (0.85 × HRmax) buried both reference athletes' measured
        // cycling values, and `thresholdHR(for:)` falling through to the athlete's own
        // running LTHR is the better answer than a constant.
        if estimateCyclingLTHRFromRides, wanted("lactate_threshold_hr_cycling"),
           !isManual("lactate_threshold_hr_cycling", asOf: date),
           let hrMax = snap.maxHR, hrMax > 0 {
            let efforts = evidence.compactMap { o -> LTHREstimate.Effort? in
                guard o.family == .bike, o.peakHR <= Double(hrMax),
                      let best = o.submaxProfile[LTHREstimate.windowSeconds] else { return nil }
                return LTHREstimate.Effort(date: o.date, steadyHR: best.hr, watts: best.watts)
            }
            if let est = LTHREstimate.estimate(efforts: efforts, hrMax: Double(hrMax),
                                               gate: .power, asOf: anchor),
               est.confidence != .rough {
                snap.cyclingLactateThrHR = Int(est.bpm.rounded())
                snap.cyclingLactateThrHRIsEstimated = true
                snap.cyclingLactateThrHRConfidence = est.confidence
            }
        }
        // One reconstruction, two thresholds: MAS is LT pace in one unit and running
        // VO2max in another, so it is resolved once here and read by both opt-ins
        // rather than aggregated twice over the same pool.
        //
        // Resting HR is a hard input, not a defaulted one: without it the reserve the
        // whole reconstruction scales by does not exist.
        let wantsPace = estimateLTPaceFromRuns && wanted("lactate_threshold_speed")
            && !isManual("lactate_threshold_speed", asOf: date)
        let wantsVO2 = estimateRunningVO2maxFromRuns && wanted("vo2max_running")
            && !isManual("vo2max_running", asOf: date)
        if wantsPace || wantsVO2, let hrMax = snap.maxHR, hrMax > 0,
           let hrRest = restingHR(asOf: date), hrRest > 0 {
            // Runs only, as `LTHREstimate` above. A triathlon or brick leg carries a
            // `ZoneMetric.pace` stream like any run, but not the relation the
            // reconstruction rests on: after hours of prior work heart rate no longer
            // tracks the metabolic cost, so `MAS = v / %HRR` reads high. One race leg
            // in a 90-day window moved this athlete's peak 12 s/km — and the pool
            // inflation the fraction divides by is calibrated on runs alone.
            let runs = evidence.compactMap { o -> (date: Date, speeds: [Double])? in
                guard o.family == .run, o.date <= anchor, o.peakHR <= Double(hrMax)
                else { return nil }
                let speeds = LTPaceEstimate.aerobicSpeeds(
                    profile: o.paceProfile, hrMax: Double(hrMax), hrRest: hrRest)
                return speeds.isEmpty ? nil : (o.date, speeds)
            }
            snap.ltPaceFractionUsed = ltPaceFraction
            if let est = LTPaceEstimate.estimate(runs: runs, asOf: anchor) {
                if wantsPace, let fraction = ltPaceFraction,
                   let speed = LTPaceEstimate.ltSpeed(mas: est.masMps, fractionOfMAS: fraction) {
                    snap.lactateThrPaceSeconds = 1000.0 / speed
                    snap.lactateThrPaceIsEstimated = true
                    snap.lactateThrPaceConfidence = est.confidence
                }
                if wantsVO2, let vo2 = VO2maxEstimate.running(mas: est.masMps) {
                    snap.vo2maxRunning = vo2
                    snap.vo2maxRunningIsEstimated = true
                    snap.vo2maxRunningConfidence = est.confidence
                }
            }
        }
        return snap
    }

    /// The thresholds an opt-in can resolve from an estimate instead of a stored
    /// reading. Nothing writes those estimates to the metric series, so their
    /// progression only exists by re-resolution — a reader of the series asks for it
    /// through `estimatedSeries`.
    static let estimatedKeys = ["vo2max_cycling", "cycling_ftp", "lactate_threshold_hr",
                                "lactate_threshold_hr_cycling", "lactate_threshold_speed",
                                "vo2max_running"]

    /// One estimated threshold's resolved progression: `snapshot(asOf:)` evaluated on
    /// every date the value can move — the estimate's inputs, the metric's own readings
    /// (a manual one outranks the estimate), and for LTHR both the day a sustained
    /// effort was recorded and the day it ages out of the observation window. Only
    /// change dates are kept, plus a final point at today so the series runs to the
    /// value in force now. Empty when the athlete hasn't opted in — the stored series
    /// stands then.
    func estimatedSeries(_ key: String) -> [MetricPoint] {
        var dates: Set<Date>
        switch key {
        case "vo2max_cycling":
            guard estimateVO2maxFromRides else { return [] }
            dates = readingDates(["max_hr", "resting_hr", "weight_kg", key])
            for o in evidence where !o.submaxProfile.isEmpty { dates.insert(o.date) }
        case "cycling_ftp":
            guard estimateFTPFromVO2max else { return [] }
            dates = readingDates(["vo2max_cycling", "weight_kg", key])
        case "lactate_threshold_hr":
            guard estimateLTHRFromHRMax else { return [] }
            dates = readingDates(["max_hr", key])
            for o in evidence where o.steadyHR20 > 0 {
                dates.insert(o.date)
                dates.insert(o.date.addingTimeInterval(Double(LTHREstimate.historyDays) * 86_400))
            }
        case "lactate_threshold_hr_cycling":
            guard estimateCyclingLTHRFromRides else { return [] }
            dates = readingDates(["max_hr", key])
            for o in evidence where o.submaxProfile[LTHREstimate.windowSeconds] != nil {
                dates.insert(o.date)
                dates.insert(o.date.addingTimeInterval(Double(LTHREstimate.historyDays) * 86_400))
            }
        case "lactate_threshold_speed", "vo2max_running":
            guard key == "vo2max_running" ? estimateRunningVO2maxFromRuns
                                          : estimateLTPaceFromRuns else { return [] }
            dates = readingDates(["max_hr", "resting_hr", key])
            for o in evidence where !o.paceProfile.isEmpty {
                dates.insert(o.date)
                dates.insert(o.date.addingTimeInterval(Double(LTPaceEstimate.historyDays) * 86_400))
            }
        default:
            return []
        }
        let now = Date()
        var out: [MetricPoint] = []
        for date in dates.filter({ $0 < now }).sorted() + [now] {
            let snap = snapshot(asOf: date, resolving: Self.estimateDependencies[key])
            // The series is stored in the metric's own unit, so LT pace goes back to
            // the m/s the `*_speed` key holds.
            // Only an estimate carries a confidence — VO2max and FTP resolve without
            // one, a stored reading is a measurement.
            let resolved: (value: Double, isEstimated: Bool, confidence: EstimateConfidence?)?
            switch key {
            case "vo2max_cycling":
                resolved = snap.vo2maxCycling.map { ($0, snap.vo2maxCyclingIsEstimated, nil) }
            case "cycling_ftp":
                resolved = snap.cyclingFTP.map { (Double($0), snap.cyclingFTPIsEstimated, nil) }
            case "lactate_threshold_hr":
                resolved = snap.lactateThrHR.map {
                    (Double($0), snap.lactateThrHRIsEstimated,
                     snap.lactateThrHRIsEstimated ? snap.lactateThrHRConfidence : nil)
                }
            case "lactate_threshold_hr_cycling":
                resolved = snap.cyclingLactateThrHR.map {
                    (Double($0), snap.cyclingLactateThrHRIsEstimated,
                     snap.cyclingLactateThrHRIsEstimated ? snap.cyclingLactateThrHRConfidence : nil)
                }
            case "vo2max_running":
                resolved = snap.vo2maxRunning.map {
                    ($0, snap.vo2maxRunningIsEstimated,
                     snap.vo2maxRunningIsEstimated ? snap.vo2maxRunningConfidence : nil)
                }
            default:
                resolved = snap.lactateThrPaceSeconds.map {
                    (1000.0 / $0, snap.lactateThrPaceIsEstimated,
                     snap.lactateThrPaceIsEstimated ? snap.lactateThrPaceConfidence : nil)
                }
            }
            guard let resolved else { continue }
            let point = MetricPoint(date: date, value: resolved.value,
                                    isEstimated: resolved.isEstimated,
                                    confidence: resolved.confidence)
            if date < now, let last = out.last, last.value == point.value,
               last.isEstimated == point.isEstimated,
               last.isProvisional == point.isProvisional { continue }
            out.append(point)
        }
        return out
    }

    /// Every date on which one of `keys` has a stored reading.
    private func readingDates(_ keys: [String]) -> Set<Date> {
        Set(keys.flatMap { byKey[$0]?.map(\.date) ?? [] })
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
    /// notification bursts. Debounced to quiescence: one pass per burst, 1.5 s after
    /// the last notification, instead of one per runloop tick. The pass dedups, then
    /// *always* notifies: an import can update or delete rows without leaving a
    /// duplicate behind, and the UI must recompute from the merged store — otherwise
    /// a long-running app displays pre-import numbers indefinitely (the listeners are
    /// pure reads, so the one coalesced reload per burst can't feed back).
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
                    self.markChanged()
                }
            }
        }
    }

    /// Every `@Model` the store owns: the workout/metric time series, the ATP
    /// inputs, and the coach-memory rows.
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
        cachedEvidence = nil
        invalidateResolvedValues()
    }

    /// Whether the stored training load and time in zone were scored against thresholds
    /// the athlete has since changed.
    ///
    /// The threshold a card shows resolves on read and so is right immediately; every
    /// activity's *score* was written at ingest against the thresholds in force then,
    /// and only `rescoreAllActivities` rewrites it. Without a marker that gap is silent
    /// — the value and the load it produced disagree with nothing on screen saying so.
    /// In UserDefaults rather than the store: it describes the store's contents, so the
    /// DB clear that resolves it must not take it along.
    static let historyNeedsRescoreKey = "history_needs_rescore"
    static var historyNeedsRescore: Bool {
        UserDefaults.standard.bool(forKey: historyNeedsRescoreKey)
    }

    /// Re-resolve every estimated threshold, without a store write having happened.
    ///
    /// These values resolve on *read* from two inputs no row records: the calculation
    /// opt-ins, and today's date (the observation window and the staleness a confidence
    /// reports both hang off `.now`). Nothing posts
    /// `trainingDataDidChange` for either, and every surface refreshes only on that —
    /// so a flipped switch and a day passing were both invisible until the next sync
    /// happened to write something.
    func invalidateResolvedValues() {
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
    /// Idempotent; saves only when a duplicate was actually removed. Change
    /// notification is the caller's concern (the remote-change burst always posts
    /// one; local ingest paths post via their own save).
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

    /// Collapse duplicate workout rows by identity, not just row id: a CloudKit
    /// merge of two offline devices can hold the same workout under *different*
    /// ids — a local plan next to the `garmin:` mirror another device created
    /// before the merge delivered the local row, or the same completed actuals
    /// folded into two such rows (double-counting the load). Does not save.
    private func dedupeWorkouts() {
        var rows = (try? context.fetch(FetchDescriptor<WorkoutRecord>())) ?? []
        guard rows.count > 1 else { return }
        // 1) Same row id — a plain CloudKit re-insert.
        rows = collapse(rows) { $0.id }
        // 2) Same Garmin plan — a local plan's pushed workout id vs the `garmin:`
        // mirror row `syncScheduledWorkouts` created while the local row hadn't
        // reached that device yet.
        rows = collapse(rows) {
            $0.externalRefs["garmin"] ?? ($0.isPlanned && $0.source == "garmin" ? Self.rawId($0.id) : nil)
        }
        // 3) Same completed activity on a folded plan AND a standalone row (each
        // side of a cross-device double-ingest). Two *plans* claiming one activity
        // are left to the provider-link correction (`applyProviderCompletions`) —
        // deleting either would drop a real plan.
        var foldedByActual: [String: WorkoutRecord] = [:]
        for row in rows where row.isPlanned && row.isCompleted {
            if let aid = row.externalRefs[Self.completedRefKey] { foldedByActual[aid] = row }
        }
        for row in rows where !row.isPlanned && row.isCompleted {
            if let plan = foldedByActual[row.id] { merge(row, into: plan) }
        }
    }

    /// Delete all but the best row per identity `key`, merging each loser into its
    /// winner; returns the survivors. Rows with a nil key pass through untouched.
    private func collapse(_ rows: [WorkoutRecord], by key: (WorkoutRecord) -> String?) -> [WorkoutRecord] {
        var winners: [String: WorkoutRecord] = [:]
        var keyless: [WorkoutRecord] = []
        for row in rows {
            guard let k = key(row) else { keyless.append(row); continue }
            guard let current = winners[k] else { winners[k] = row; continue }
            let winner = Self.outranks(current, row) ? current : row
            merge(winner === current ? row : current, into: winner)
            winners[k] = winner
        }
        return keyless + winners.values
    }

    /// Fold a losing duplicate onto its winner — external refs it alone carries
    /// plus its completed section if the winner's is absent or unscored (the two
    /// sections describe the same activity, but only one device may have had the
    /// thresholds to score its TL) — then delete it.
    private func merge(_ loser: WorkoutRecord, into winner: WorkoutRecord) {
        for (k, v) in loser.externalRefs where winner.externalRefs[k] == nil {
            winner.setExternalRef(target: k, externalId: v)
        }
        if loser.isCompleted && (!winner.isCompleted || (winner.tss == nil && loser.tss != nil)) {
            if winner.overridesJSON == "{}" { winner.overridesJSON = loser.overridesJSON }
            Self.applyCompleted(CompletedSection(loser), to: winner)
        }
        context.delete(loser)
    }

    /// Winner between two rows for the same workout: the locally-authored row is
    /// authoritative (plan edits and the write-target reconcile key off it), then a
    /// completed section beats a plan-only row, a plan beats neither, then the
    /// richer `detailsJSON` wins.
    private static func outranks(_ a: WorkoutRecord, _ b: WorkoutRecord) -> Bool {
        if (a.source == "local") != (b.source == "local") { return a.source == "local" }
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

    /// Drop every stored reading of one metric key.
    ///
    /// Needed because a *setting* synced as a dated observation can never be
    /// corrected in place: each sync stamps today, so a wrong value stays on the
    /// dates it was written and no resync rewrites it. Returns how many rows went.
    @discardableResult
    func deleteMetricSeries(_ key: String) -> Int {
        let rows = (try? context.fetch(FetchDescriptor<PerformanceMetricRecord>(
            predicate: #Predicate { $0.metricKey == key }))) ?? []
        guard !rows.isEmpty else { return 0 }
        for r in rows { context.delete(r) }
        try? context.save()
        markChanged()
        return rows.count
    }

    /// One-time translation of rows written before the planned/actual/override
    /// layers existed: give every plan its own `plannedDate`/`plannedStartMinute`,
    /// move every completed row's `date`/`startMinute` to the activity's real start
    /// (recovered from the source record in `detailsJSON` — a folded plan otherwise
    /// sits on the planned day, not the day the workout was done), and lift the
    /// athlete-edit keys into the override layer. Safe to re-run (e.g. on a second
    /// device whose CloudKit mirror already carries migrated rows): the planned
    /// slot is only filled when absent and the completed part is idempotent.
    func migrateWorkoutLayersIfNeeded() {
        let flag = "workout_layers_migrated"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let rows = (try? context.fetch(FetchDescriptor<WorkoutRecord>())) ?? []
        for r in rows {
            if r.isPlanned && r.plannedDate == nil {
                r.plannedDate = Calendar.current.startOfDay(for: r.date)
                r.plannedStartMinute = r.startMinute
            }
            guard r.isCompleted, let details = Self.jsonObject(r.detailsJSON) else { continue }
            if let ymd = details["date"] as? String, let actual = DateFormatter.ymd.date(from: ymd) {
                r.date = actual
            }
            if let minute = WorkoutRecord.clockMinute(fromDetails: r.detailsJSON) {
                r.startMinute = minute
            }
            if r.overridesJSON == "{}" {
                let edits = details.filter { $0.key == "manual_distance_m" || $0.key == "manual_name" }
                if !edits.isEmpty { r.overridesJSON = Self.jsonString(edits) ?? "{}" }
            }
        }
        if !rows.isEmpty {
            try? context.save()
            markChanged()
        }
        UserDefaults.standard.set(true, forKey: flag)
    }

    // MARK: - Completed activities

    /// Upsert a batch of completed activities (insert new, update existing by id),
    /// scoring each one's TSS + effective distance here — the single place it
    /// happens, so every data source gets consistent TSS without knowing about it.
    /// Each activity is scored against `snapshot(asOf: a.date)`, i.e. the thresholds
    /// current on its own date.
    ///
    /// When an open plan's completion link (`externalRefs["completed"]`, set from
    /// the provider's calendar or a manual link) names an activity, the completed
    /// section is folded INTO that plan row (TrainingPeaks-style planned+actual on
    /// one row) and no separate activity row is inserted, so the load is never
    /// double-counted. The explicit link is the *only* pairing — there is no
    /// date/sport matching.
    func ingest(_ activities: [IngestedActivity]) {
        guard !activities.isEmpty else { return }
        let perf = Perf.begin("ingest", "\(activities.count)"); defer { Perf.end(perf) }
        // Blacklisted by the athlete → never give it a row (so it stays gone from every
        // surface and never re-syncs). Dropped before scoring and folding.
        let ignored = IgnoredWorkouts.ids
        let incoming = activities.filter { !ignored.contains($0.id) }
        // The LTHR estimate reads its sustained efforts out of the stored rows, so a
        // pass that rewrites those rows would score itself against the evidence it is
        // replacing — and a full re-sync, which rewrites everything, against none at
        // all. Reading the batch's evidence first and resolving the thresholds with it
        // makes the pass self-consistent: no re-score afterwards to get the same answer.
        let evidence = incoming.map(Self.evidence)
        let history = performanceHistory(adding: evidence)
        // Plans keyed by their completion link: a folded plan refreshes its actuals
        // in place on re-sync; an open plan absorbs the linked activity when it
        // arrives. `externalRefs` is JSON-decoded, so it can't sit in a
        // `#Predicate` — one fetch + decode pass serves the whole batch.
        var foldedPlans: [String: WorkoutRecord] = [:]
        var linkedOpenPlans: [String: WorkoutRecord] = [:]
        for plan in (try? context.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isPlanned }))) ?? [] {
            guard let aid = plan.externalRefs[Self.completedRefKey] else { continue }
            if plan.isCompleted { foldedPlans[aid] = plan } else { linkedOpenPlans[aid] = plan }
        }
        for (a, hr) in zip(incoming, evidence) {
            let scored = Self.score(a, history: history, hr: hr)
            let id = a.id
            let record: WorkoutRecord
            // 1) Already folded into a completed plan (its actuals live on the plan
            // row, keyed by `completedRef` — not by this id) → refresh that plan in
            // place and drop any stray standalone with this id, never re-insert.
            if let plan = foldedPlans[id] {
                record = plan
                if let stray = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
                    predicate: #Predicate { $0.id == id && !$0.isPlanned })))?.first {
                    context.delete(stray)
                }
            // 2) An existing row already keyed by this activity id → update in place.
            } else if let existing = (try? context.fetch(
                FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })))?.first {
                record = existing
            // 3) An open plan whose completion link names this activity → fold in.
            } else if let plan = linkedOpenPlans[id] {
                record = plan
            // 4) Else a fresh completed-only row.
            } else {
                record = WorkoutRecord(id: a.id, source: a.source, date: a.date, sport: a.sport, name: a.name)
                context.insert(record)
            }
            Self.applyCompleted(CompletedSection(a, scored: scored), to: record)
            applyOverrides(record, history: history)
        }
        dedupeWorkouts()
        try? context.save()
        markChanged()
    }

    /// A row's completed section as one value — the single field list every writer
    /// (DTO ingest, fold, dedupe merge) copies, so the copies can never drift.
    private struct CompletedSection {
        let source: String, date: Date, startMinute: Int?, sport: String, name: String
        let durationMinutes: Double, distanceKm: Double
        let tss: Double?, tssBasis: String?
        let detailsJSON: String, powerCurveJSON: String
        let streamsData: Data, zoneHistogramData: Data
        let segmentsJSON: String
        let steadyHR20: Double, peakHR: Double
        let paceHRProfileJSON: String
        let submaxProfileJSON: String

        init(_ a: IngestedActivity, scored: ScoredActivity) {
            source = a.source; date = a.date
            startMinute = WorkoutRecord.clockMinute(fromDetails: scored.detailsJSON)
            sport = a.sport; name = a.name
            durationMinutes = a.durationMinutes; distanceKm = scored.distanceKm
            tss = scored.tss; tssBasis = scored.basis
            detailsJSON = scored.detailsJSON; powerCurveJSON = a.powerCurveJSON
            streamsData = a.streamsData; zoneHistogramData = scored.zoneHistogramData
            segmentsJSON = scored.segmentsJSON
            steadyHR20 = scored.steadyHR20; peakHR = scored.peakHR
            paceHRProfileJSON = scored.paceHRProfileJSON
            submaxProfileJSON = scored.submaxProfileJSON
        }

        init(_ r: WorkoutRecord) {
            source = r.source; date = r.date; startMinute = r.startMinute
            sport = r.sport; name = r.name
            durationMinutes = r.durationMinutes; distanceKm = r.distanceKm
            tss = r.tss; tssBasis = r.tssBasis
            detailsJSON = r.detailsJSON; powerCurveJSON = r.powerCurveJSON
            streamsData = r.streamsData; zoneHistogramData = r.zoneHistogramData
            segmentsJSON = r.segmentsJSON
            steadyHR20 = r.steadyHR20; peakHR = r.peakHR
            paceHRProfileJSON = r.paceHRProfileJSON
            submaxProfileJSON = r.submaxProfileJSON
        }
    }

    /// Write `c` onto `record` — the only place a completed section lands on a row.
    /// The actual date/start time always win, so a plan done a day early or late
    /// shows on the day it was actually done (the planned slot survives in
    /// `plannedDate`/`plannedStartMinute`). A plan keeps its user-authored
    /// source/sport/name; athlete edits are re-applied afterwards by
    /// `applyOverrides`.
    private static func applyCompleted(_ c: CompletedSection, to record: WorkoutRecord) {
        if !record.isPlanned {
            record.source = c.source
            record.sport = c.sport
            record.name = c.name
        }
        record.isCompleted = true
        record.date = c.date
        record.startMinute = c.startMinute ?? record.startMinute
        record.durationMinutes = c.durationMinutes
        record.distanceKm = c.distanceKm
        record.tss = c.tss
        record.tssBasis = c.tssBasis
        record.detailsJSON = c.detailsJSON
        record.powerCurveJSON = c.powerCurveJSON
        record.streamsData = c.streamsData
        record.zoneHistogramData = c.zoneHistogramData
        record.segmentsJSON = c.segmentsJSON
        record.submaxProfileJSON = c.submaxProfileJSON
        record.steadyHR20 = c.steadyHR20
        record.peakHR = c.peakHR
        record.paceHRProfileJSON = c.paceHRProfileJSON
    }

    /// Re-materialize the athlete's stored edits (`overridesJSON`) onto a freshly
    /// written completed section — the durable half of every manual correction, so
    /// a resync can rewrite the source data blindly without losing them. A name
    /// override lands on `name`; a distance override re-scores distance + TSS.
    private func applyOverrides(_ r: WorkoutRecord, history: PerformanceHistory) {
        guard r.overridesJSON != "{}",
              let ov = Self.jsonObject(r.overridesJSON), !ov.isEmpty,
              var details = Self.jsonObject(r.detailsJSON) else { return }
        for (k, v) in ov { details[k] = v }
        if let name = ov["manual_name"] as? String { r.name = name }
        if ov["manual_distance_m"] != nil {
            let (km, tss, basis) = TSSScoring.score(&details, snapshot: history.snapshot(asOf: r.date),
                                                    zoneSamples: ZoneHistogram.decode(r.zoneHistogramData) ?? [:])
            r.distanceKm = km
            r.tss = tss
            r.tssBasis = basis
        }
        r.detailsJSON = Self.jsonString(details) ?? r.detailsJSON
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

    struct ScoredActivity {
        let tss: Double?, distanceKm: Double, detailsJSON: String, basis: String?
        var segmentsJSON: String = ""
        var steadyHR20: Double = 0
        var peakHR: Double = 0
        var paceHRProfileJSON: String = ""
        var submaxProfileJSON: String = ""
        var zoneHistogramData: Data = Data()
    }

    /// The threshold evidence one incoming activity carries (`LTHREstimate`,
    /// `LTPaceEstimate`), read here rather than in any source: the HR and
    /// grade-adjusted pace streams the sources already shape for zone bucketing are
    /// the same input. One unit per scored effort — legs are separate efforts, and
    /// concatenating them would let a 20-minute window straddle a transition, or pair
    /// a bike heart rate with a run pace.
    private static func evidence(_ a: IngestedActivity) -> PerformanceHistory.ActivityEvidence {
        let units = a.zoneSamples.isEmpty ? Array(a.legZoneSamples.values) : [a.zoneSamples]
        let hrStreams = units.compactMap { $0[.heartRate] }
        // Only a unit carrying BOTH streams can be paired; `ZoneMetric.pace` exists
        // for runs alone, so this is empty for every other sport.
        var profile: [Int: Double] = [:]
        for unit in units {
            guard let pace = unit[.pace], let hr = unit[.heartRate] else { continue }
            for (bpm, speed) in LTPaceEstimate.profile(gradeAdjustedSpeed: pace, heartRate: hr)
            where speed > profile[bpm] ?? 0 {
                profile[bpm] = speed
            }
        }
        var submax: [Int: (watts: Double, hr: Double)] = [:]
        for unit in units {
            guard let power = unit[.power], let hr = unit[.heartRate] else { continue }
            for (seconds, pair) in VO2maxEstimate.profile(power: power, heartRate: hr)
            where pair.watts > submax[seconds]?.watts ?? 0 {
                submax[seconds] = pair
            }
        }
        return .init(date: a.date,
                     steadyHR20: hrStreams.compactMap(LTHREstimate.steadyWindow).max() ?? 0,
                     peakHR: hrStreams.flatMap { $0.map(\.value) }.max() ?? 0,
                     paceProfile: profile, submaxProfile: submax,
                     family: SportFamily(sportKey: a.sport))
    }

    /// Score one incoming activity against the thresholds current on its date.
    /// A multisport activity is scored per leg and summed — its parent details
    /// carry no per-discipline data, so only the legs are scorable.
    private static func score(_ a: IngestedActivity, history: PerformanceHistory,
                              hr: PerformanceHistory.ActivityEvidence) -> ScoredActivity {
        let snapshot = history.snapshot(asOf: a.date)
        if !a.segmentsJSON.isEmpty {
            var segments = WorkoutSegments.decode(a.segmentsJSON)
            for i in segments.indices {
                guard let samples = segments[i].sourceId.flatMap({ a.legZoneSamples[$0] }) else { continue }
                segments[i].zoneHistogramData = ZoneHistogram.encode(samples)
            }
            let (km, tss, basis) = TSSScoring.scoreSegments(&segments, snapshot: snapshot,
                                                           zoneSamples: a.legZoneSamples)
            return ScoredActivity(tss: tss, distanceKm: km, detailsJSON: a.detailsJSON,
                                  basis: basis, segmentsJSON: WorkoutSegments.encode(segments),
                                  steadyHR20: hr.steadyHR20, peakHR: hr.peakHR,
                                  paceHRProfileJSON: LTPaceEstimate.encode(hr.paceProfile),
                                  submaxProfileJSON: VO2maxEstimate.encode(hr.submaxProfile))
        }
        guard var details = jsonObject(a.detailsJSON) else {
            return ScoredActivity(tss: nil, distanceKm: a.distanceKm, detailsJSON: a.detailsJSON,
                                  basis: nil, steadyHR20: hr.steadyHR20, peakHR: hr.peakHR,
                                  paceHRProfileJSON: LTPaceEstimate.encode(hr.paceProfile),
                                  submaxProfileJSON: VO2maxEstimate.encode(hr.submaxProfile))
        }
        let (km, tss, basis) = TSSScoring.score(&details, snapshot: snapshot,
                                                zoneSamples: a.zoneSamples)
        return ScoredActivity(tss: tss, distanceKm: km,
                              detailsJSON: jsonString(details) ?? a.detailsJSON, basis: basis,
                              steadyHR20: hr.steadyHR20, peakHR: hr.peakHR,
                              paceHRProfileJSON: LTPaceEstimate.encode(hr.paceProfile),
                              submaxProfileJSON: VO2maxEstimate.encode(hr.submaxProfile),
                              zoneHistogramData: ZoneHistogram.encode(a.zoneSamples))
    }

    /// Cached `(tss, detailsJSON)` for the given ids — a resync passes the ids it is
    /// about to fetch so already-stored workouts can be reused without re-fetching
    /// their streams / recomputing TSS (purely a fetch-avoidance cache; the
    /// athlete's manual edits survive independently via the override layer).
    /// Resolves the raw provider id against folded plan rows too.
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

    /// Manually override one completed activity's distance (km). The edit lives in
    /// the override layer (survives any resync) and recomputes distance + TSS.
    func overrideDistance(activityId: String, distanceKm: Double) {
        guard let r = activity(id: activityId) else { return }
        setOverrides(["manual_distance_m": distanceKm * 1000], on: r)
    }

    /// Re-run TSS + effective-distance scoring on the stored details against the
    /// thresholds current on the activity's date — no refetch, so already-fetched
    /// data picks up algorithm/threshold changes.
    func rescoreActivity(id: String) {
        guard let r = activity(id: id), var details = Self.jsonObject(r.detailsJSON) else { return }
        rescore(r, details: &details)
    }

    private func rescore(_ r: WorkoutRecord, details: inout [String: Any]) {
        let (km, tss, basis) = TSSScoring.score(&details, snapshot: performanceHistory().snapshot(asOf: r.date),
                                                zoneSamples: ZoneHistogram.decode(r.zoneHistogramData) ?? [:])
        r.distanceKm = km
        r.tss = tss
        r.tssBasis = basis
        r.detailsJSON = Self.jsonString(details) ?? r.detailsJSON
        try? context.save()
        markChanged()
    }

    /// Rename one completed activity. The name outranks the source's on every
    /// re-sync and refetch (override layer).
    func renameActivity(id: String, name: String) {
        guard let r = activity(id: id) else { return }
        setOverrides(["manual_name": name], on: r)
    }

    /// Replace one completed strength session's recorded sets with the athlete's
    /// corrected list (`StrengthSets.entries`). Outranks the source's sets on
    /// every re-sync (override layer); nothing goes back to the watch's account.
    func overrideStrengthSets(activityId: String, exercises: [[String: Any]]) {
        guard let r = activity(id: activityId) else { return }
        setOverrides(["strength": ["exercises": exercises]], on: r)
    }

    /// Record the athlete's subjective feedback (feel 1–5, RPE 1–10, free-text
    /// note) on a completed activity. Matches the stored id or a source-prefixed
    /// variant of the raw provider id. Returns false when no matching completed
    /// workout exists.
    func setWorkoutFeedback(activityId: String, feel: Int?, rpe: Int?, note: String?) -> Bool {
        let candidates = [activityId, "garmin:\(activityId)", "healthkit:\(activityId)", "local:\(activityId)"]
        guard let r = (try? context.fetch(
            FetchDescriptor<WorkoutRecord>(predicate: #Predicate { candidates.contains($0.id) && $0.isCompleted })))?.first
        else { return false }
        var edits: [String: Any] = [:]
        if let feel { edits["feel"] = feel }
        if let rpe { edits["rpe"] = rpe }
        if let note { edits["notes"] = note }
        setOverrides(edits, on: r)
        return true
    }

    /// Merge athlete edits into a row's override layer and re-materialize them
    /// onto the completed section.
    private func setOverrides(_ edits: [String: Any], on r: WorkoutRecord) {
        var ov = Self.jsonObject(r.overridesJSON) ?? [:]
        for (k, v) in edits { ov[k] = v }
        r.overridesJSON = Self.jsonString(ov) ?? r.overridesJSON
        applyOverrides(r, history: performanceHistory())
        try? context.save()
        markChanged()
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

    /// The weight the athlete last prescribed for this exercise, from the most
    /// recent planned strength session that used it. The athlete's own last
    /// working weight is the only honest starting point — there is no max test.
    func lastPlannedWeightKg(exerciseId: String, before: Date = .now) -> Double? {
        var descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isPlanned && $0.date < before },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 60
        for plan in (try? context.fetch(descriptor)) ?? [] {
            guard SportFamily(sportKey: plan.sport) == .strength,
                  let steps = WorkoutPayloadBuilder.parseSteps(plan.stepsJSON) else { continue }
            if let kg = Self.plannedWeight(in: steps, exerciseId: exerciseId) { return kg }
        }
        return nil
    }

    /// This exercise's sets in the most recent completed session that has it —
    /// what was lifted, matched on the key plan and record share
    /// (`SetRow.garminKey`). Empty when it was never recorded.
    func lastLiftedSets(key: String, before: Date = .now) -> [StrengthSets.SetRow] {
        var descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isCompleted && $0.date < before },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 60
        for record in (try? context.fetch(descriptor)) ?? [] where SportFamily(sportKey: record.sport) == .strength {
            let entries = (Self.jsonObject(record.detailsJSON)?["strength"] as? [String: Any])?["exercises"] as? [[String: Any]]
            let sets = StrengthSets.rows(performed: entries ?? []).filter { $0.garminKey == key }
            if !sets.isEmpty { return sets }
        }
        return []
    }

    /// Where a new prescription of `exercise` starts: the heaviest set the athlete
    /// last lifted on it, else the weight they last planned. Nil = bodyweight.
    func startingWeightKg(for exercise: Exercise) -> Double? {
        lastLiftedSets(for: exercise).compactMap(\.weightKg).max() ?? lastPlannedWeightKg(exerciseId: exercise.id)
    }

    func lastLiftedSets(for exercise: Exercise) -> [StrengthSets.SetRow] {
        lastLiftedSets(key: StrengthSets.SetRow(exerciseId: exercise.id, exerciseName: exercise.name).garminKey ?? exercise.name)
    }

    /// Depth-first through circuits: the first set of the named exercise that
    /// carries a weight (a bodyweight prescription deliberately reports none).
    private static func plannedWeight(in steps: [[String: Any]], exerciseId: String) -> Double? {
        for step in steps {
            if let children = step["repeat_steps"] as? [[String: Any]],
               let kg = plannedWeight(in: children, exerciseId: exerciseId) { return kg }
            guard step["exercise_id"] as? String == exerciseId,
                  let sets = step["sets"] as? [[String: Any]] else { continue }
            if let kg = sets.compactMap({ Coerce.double($0["weight_kg"]) }).first(where: { $0 > 0 }) { return kg }
        }
        return nil
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
    /// already-recorded completed section intact (only the plan fields change) —
    /// including `date`, which on a folded row is the actual day, not the planned
    /// one still on the provider's calendar.
    func ingestScheduled(_ workouts: [IngestedScheduledWorkout]) {
        guard !workouts.isEmpty else { return }
        let cal = Calendar.current
        for w in workouts {
            let id = w.id
            let day = cal.startOfDay(for: w.date)
            if let record = (try? context.fetch(
                FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })))?.first {
                record.source = w.source
                record.plannedDate = day
                if !record.isCompleted { record.date = day }
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
                rec.plannedDate = day
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

    /// Fold a standalone completed `activity` into an open `plan`: move its actuals
    /// (and athlete edits) onto the plan row, link it (`completedRef`) and drop the
    /// standalone — the single place a separate completed row collapses into its
    /// plan, shared by the calendar-driven `foldStandaloneCompleted` and the manual
    /// `linkActual`. The plan row moves to the activity's actual date/start time;
    /// its planned slot stays in `plannedDate`/`plannedStartMinute`.
    private func fold(activity: WorkoutRecord, into plan: WorkoutRecord) {
        plan.overridesJSON = activity.overridesJSON
        Self.applyCompleted(CompletedSection(activity), to: plan)
        plan.setExternalRef(target: Self.completedRefKey, externalId: activity.id)
        context.delete(activity)
    }

    // MARK: - Manual pairing override
    //
    // The automatic ingest fold pairs a completed activity to a plan only by the
    // provider's explicit completion link. Where no link exists (Apple Watch plans
    // have no HealthKit→plan link) or it names the wrong session, these two let
    // the athlete pair by hand: split a wrong pairing, then attach the right
    // activity.

    /// Split a folded plan row (`isPlanned && isCompleted`) back into an open plan
    /// and a standalone completed activity. The actual is re-materialized as its own
    /// row keyed by the completion id (`externalRefs["completed"]`), so it is
    /// preserved and re-upserts in place on the next provider sync; the plan
    /// returns to open. No-op unless the row is a folded plan carrying a completion link.
    func unlinkActual(planId: String) {
        guard let plan = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.id == planId && $0.isPlanned && $0.isCompleted }
        )))?.first else { return }
        unfold(plan)
        try? context.save()
        markChanged()
    }

    /// Split a folded plan back into an open plan + a standalone completed row.
    /// The plan returns to its planned slot (`plannedDate`/`plannedStartMinute`);
    /// the standalone keeps the actual date/time and the athlete's edits. Does not
    /// save; no-op without a completion link.
    private func unfold(_ plan: WorkoutRecord) {
        guard let activityId = plan.externalRefs[Self.completedRefKey] else { return }
        let activity = WorkoutRecord(
            id: activityId,
            source: activityId.components(separatedBy: ":").first ?? plan.source,
            date: plan.date, sport: plan.sport,
            name: SportFamily(sportKey: plan.sport).displayName,
            startMinute: plan.startMinute,
            isCompleted: true,
            durationMinutes: plan.durationMinutes, distanceKm: plan.distanceKm,
            tss: plan.tss, tssBasis: plan.tssBasis,
            detailsJSON: plan.detailsJSON, powerCurveJSON: plan.powerCurveJSON,
            streamsData: plan.streamsData
        )
        activity.overridesJSON = plan.overridesJSON
        context.insert(activity)
        plan.isCompleted = false
        plan.date = plan.plannedDate ?? plan.date
        plan.startMinute = plan.plannedStartMinute
        plan.durationMinutes = 0
        plan.distanceKm = 0
        plan.tss = nil
        plan.tssBasis = nil
        plan.detailsJSON = ""
        plan.powerCurveJSON = ""
        plan.streamsData = Data()
        plan.overridesJSON = "{}"
        plan.setExternalRef(target: Self.completedRefKey, externalId: nil)
    }

    /// Apply the provider's authoritative plan→activity completion links to plans
    /// pushed to `target` (`links`: provider workout id → raw activity id). Garmin's
    /// calendar names the activity that completed each workout; a contradicting
    /// pairing (a manual link to another session, or a link the provider changed)
    /// is undone first (the stray actual re-materializes as a standalone row and
    /// re-pairs on the next ingest) before the named activity is linked and folded in.
    func applyProviderCompletions(target: String, links: [String: String]) {
        guard !links.isEmpty else { return }
        let plans = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isPlanned }
        ))) ?? []
        var changed = false
        for plan in plans {
            guard let workoutId = plan.externalRefs[target],
                  let rawActivityId = links[workoutId] else { continue }
            let activityId = "\(target):\(rawActivityId)"
            guard plan.externalRefs[Self.completedRefKey] != activityId else { continue }
            if plan.isCompleted { unfold(plan) }
            plan.setExternalRef(target: Self.completedRefKey, externalId: activityId)
            foldStandaloneCompleted(into: plan, source: target, rawActivityId: rawActivityId)
            changed = true
        }
        guard changed else { return }
        dedupeWorkouts()
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

    /// All open plans (`isPlanned && !isCompleted`), nearest planned day to
    /// `activity` first — the candidates the detail view offers for a manual link.
    /// Deliberately unfiltered: pairing is the athlete's explicit choice, never a
    /// date/sport match.
    func openPlansMatching(activity: WorkoutRecord) -> [WorkoutRecord] {
        let plans = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isPlanned && !$0.isCompleted }
        ))) ?? []
        return plans.sorted {
            abs($0.date.timeIntervalSince(activity.date)) < abs($1.date.timeIntervalSince(activity.date))
        }
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
        let day = Calendar.current.startOfDay(for: newDate)
        record.plannedDate = day
        if !record.isCompleted { record.date = day }
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

    /// Re-estimate every planned row's target TSS from its stored steps against
    /// the current thresholds. Plan edits recompute in place, but a threshold
    /// correction (or a historically mis-scored row) doesn't reach already-stored
    /// values — this is the Developer "Recompute planned TSS" action. Returns how
    /// many rows changed.
    func recomputePlannedTSS() -> Int {
        let plans = (try? context.fetch(
            FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.isPlanned })
        )) ?? []
        let thresholds = latestSnapshot()
        var changed = 0
        for plan in plans {
            let tss = PlannedTSS.estimate(
                compactSteps: WorkoutPayloadBuilder.parseSteps(plan.stepsJSON) ?? [],
                family: SportFamily(sportKey: plan.sport),
                thresholds: thresholds
            )
            if plan.targetTSS != tss {
                plan.targetTSS = tss
                changed += 1
            }
        }
        guard changed > 0 else { return 0 }
        try? context.save()
        markChanged()
        return changed
    }

    /// Set (or clear) a planned workout's local time-of-day, in minutes after
    /// midnight. Returns the updated record.
    @discardableResult
    func setScheduledStartMinute(id: String, minute: Int?) -> WorkoutRecord? {
        let record = try? context.fetch(
            FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })
        ).first
        guard let record else { return nil }
        record.plannedStartMinute = minute
        if !record.isCompleted { record.startMinute = minute }
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
            record.plannedDate = nil
            record.plannedStartMinute = nil
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
                r.plannedStartMinute = minute
                if !r.isCompleted { r.startMinute = minute }
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

    /// Source preference when two records share the newest day for a metric. A
    /// hand-entered value outranks a synced one — the athlete's correction wins on
    /// its day (see `setManualMetric`).
    private static func sourceRank(_ source: String) -> Int {
        switch source {
        case "manual": return PerformanceHistory.manualRank
        case "garmin": return 2
        default: return 1   // "healthkit"
        }
    }

    /// The full performance-metric history as a point-in-time–queryable resolver.
    /// `adding` contributes HR evidence the store doesn't hold yet — the activities of
    /// an ingest pass in flight (see `ingest`); it never enters the cache.
    func performanceHistory(adding incoming: [PerformanceHistory.ActivityEvidence] = []) -> PerformanceHistory {
        let records = (try? context.fetch(FetchDescriptor<PerformanceMetricRecord>())) ?? []
        var byKey: [String: [PerformanceHistory.Entry]] = [:]
        for r in records {
            byKey[r.metricKey, default: []].append(
                .init(date: r.date, value: r.value, rank: Self.sourceRank(r.source))
            )
        }
        let estimateLTHR = UserDefaults.standard.bool(forKey: AppSettings.estimateLTHRFromHRMaxKey)
        let estimateLTPace = UserDefaults.standard.bool(forKey: AppSettings.estimateLTPaceFromRunsKey)
        let estimateRunVO2 = UserDefaults.standard.bool(forKey: AppSettings.estimateRunningVO2maxFromRunsKey)
        let estimateBikeLTHR = UserDefaults.standard.bool(forKey: AppSettings.estimateCyclingLTHRFromRidesKey)
        let estimateFTP = UserDefaults.standard.bool(forKey: AppSettings.estimateFTPFromVO2maxKey)
        let estimateVO2max = UserDefaults.standard.bool(forKey: AppSettings.estimateVO2maxFromRidesKey)
        // Only fetched when an estimate that reads it is switched on, and cached
        // because this runs per list row: `WorkoutRecord` has no partial fault here,
        // so each fetch otherwise materializes every stored stream blob.
        var observations: [PerformanceHistory.ActivityEvidence] = []
        if estimateLTHR || estimateLTPace || estimateVO2max || estimateRunVO2 || estimateBikeLTHR {
            if let cached = cachedEvidence { observations = cached } else {
                let rows = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
                    predicate: #Predicate {
                        $0.isCompleted && ($0.steadyHR20 > 0 || $0.paceHRProfileJSON != ""
                                           || $0.submaxProfileJSON != "")
                    }))) ?? []
                observations = rows.map {
                    .init(date: $0.date, steadyHR20: $0.steadyHR20, peakHR: $0.peakHR,
                          paceProfile: LTPaceEstimate.decode($0.paceHRProfileJSON),
                          submaxProfile: VO2maxEstimate.decode($0.submaxProfileJSON),
                          family: SportFamily(sportKey: $0.sport))
                }
                cachedEvidence = observations
            }
            observations += incoming.filter {
                $0.steadyHR20 > 0 || !$0.paceProfile.isEmpty || !$0.submaxProfile.isEmpty
            }
        }
        return PerformanceHistory(
            byKey: byKey,
            estimateFTPFromVO2max: estimateFTP,
            estimateVO2maxFromRides: estimateVO2max,
            estimateLTHRFromHRMax: estimateLTHR,
            estimateLTPaceFromRuns: estimateLTPace,
            estimateRunningVO2maxFromRuns: estimateRunVO2,
            estimateCyclingLTHRFromRides: estimateBikeLTHR,
            ltPaceFractionOverride: AppSettings.storedLTPaceFraction,
            evidence: observations)
    }

    /// Re-bucketing input for one multisport row: each leg's stored histogram, keyed
    /// the way `scoreSegments` looks legs up.
    private static func legZoneSamples(_ segments: [WorkoutSegment]) -> [String: ZoneSamples] {
        Dictionary(segments.compactMap { s in
            s.sourceId.flatMap { id in ZoneHistogram.decode(s.zoneHistogramData).map { (id, $0) } }
        }, uniquingKeysWith: { a, _ in a })
    }

    /// Re-score every completed activity in place against the current thresholds —
    /// the hook for a threshold opt-in that moves every past date. Time in zone is
    /// re-bucketed from each row's stored `ZoneHistogram`, so the result matches a
    /// full re-ingest exactly; a row stored before histograms existed keeps the zones
    /// it was ingested with and needs a `resync(source:)` to pick them up.
    /// Reports `(done, total)` as it goes and yields periodically so the caller can
    /// render it; everything stays on the main actor, where the models live.
    @discardableResult
    func rescoreAllActivities(progress: (Int, Int) -> Void = { _, _ in }) async -> Int {
        let rows = (try? context.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isCompleted }))) ?? []
        let history = performanceHistory()
        for (i, r) in rows.enumerated() {
            let snapshot = history.snapshot(asOf: r.date)
            // Overrides are already materialised into detailsJSON, so re-scoring the
            // stored details preserves the athlete's edits.
            if !r.segmentsJSON.isEmpty {
                var segments = WorkoutSegments.decode(r.segmentsJSON)
                let (km, tss, basis) = TSSScoring.scoreSegments(
                    &segments, snapshot: snapshot, zoneSamples: Self.legZoneSamples(segments))
                r.segmentsJSON = WorkoutSegments.encode(segments)
                (r.distanceKm, r.tss, r.tssBasis) = (km, tss, basis)
            } else if var details = Self.jsonObject(r.detailsJSON) {
                let (km, tss, basis) = TSSScoring.score(
                    &details, snapshot: snapshot,
                    zoneSamples: ZoneHistogram.decode(r.zoneHistogramData) ?? [:])
                (r.distanceKm, r.tss, r.tssBasis) = (km, tss, basis)
                r.detailsJSON = Self.jsonString(details) ?? r.detailsJSON
            }
            if i % 25 == 0 || i == rows.count - 1 {
                progress(i + 1, rows.count)
                await Task.yield()
            }
        }
        try? context.save()
        UserDefaults.standard.set(false, forKey: Self.historyNeedsRescoreKey)
        markChanged()
        return rows.count
    }

    /// Latest value per metric key — the source for the coach's prompt context,
    /// the Settings display, and the planned-workout estimators. Cached because the
    /// estimators read it per list row; `markChanged()` invalidates on any mutation.
    /// The estimate opt-ins change how a threshold resolves without touching a row,
    /// so the cache carries the flags it was built under rather than relying on
    /// whoever flips them to invalidate it.
    /// What the cached snapshot was resolved under.
    private struct Key: Equatable { let flags: [Bool]; let fraction: Double? }
    private var cachedLatestSnapshot: (key: Key, snapshot: PerformanceSnapshot)?
    private var cachedEvidence: [PerformanceHistory.ActivityEvidence]?
    func latestSnapshot() -> PerformanceSnapshot {
        // The fraction moves the LT pace without moving a switch, so it is part of the
        // key too, or the slider stays invisible until something else invalidates.
        let key = Key(flags: [UserDefaults.standard.bool(forKey: AppSettings.estimateFTPFromVO2maxKey),
                              UserDefaults.standard.bool(forKey: AppSettings.estimateVO2maxFromRidesKey),
                              UserDefaults.standard.bool(forKey: AppSettings.estimateLTHRFromHRMaxKey),
                              UserDefaults.standard.bool(forKey: AppSettings.estimateLTPaceFromRunsKey),
                              UserDefaults.standard.bool(forKey: AppSettings.estimateRunningVO2maxFromRunsKey),
                              UserDefaults.standard.bool(forKey: AppSettings.estimateCyclingLTHRFromRidesKey)],
                      fraction: AppSettings.storedLTPaceFraction)
        if let cached = cachedLatestSnapshot, cached.key == key { return cached.snapshot }
        let snap = performanceHistory().snapshot(asOf: .distantFuture)
        cachedLatestSnapshot = (key, snap)
        return snap
    }

    /// Ascending day-by-day history for one metric key — the progression the
    /// Statistics charts plot. A threshold the athlete estimates has no stored series
    /// to read: it resolves per date, so it is re-derived (and flagged) instead.
    func metricHistory(_ key: String) -> [MetricPoint] {
        if PerformanceHistory.estimatedKeys.contains(key) {
            let estimated = performanceHistory().estimatedSeries(key)
            if !estimated.isEmpty { return estimated }
        }
        return storedHistory(key)
    }

    /// `metricHistory` with the re-resolution off the main actor. The store fetch has
    /// to stay here — the models are `@MainActor` — but `PerformanceHistory` is a
    /// `Sendable` value, and for an estimated key the per-date re-resolution is all of
    /// the cost: a hundred-odd dates over every stored run.
    func metricHistory(_ key: String) async -> [MetricPoint] {
        if PerformanceHistory.estimatedKeys.contains(key) {
            let history = performanceHistory()
            let estimated = await Task.detached { history.estimatedSeries(key) }.value
            if !estimated.isEmpty { return estimated }
        }
        return storedHistory(key)
    }

    private func storedHistory(_ key: String) -> [MetricPoint] {
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

    // MARK: - Manual entry

    /// Write a hand-entered performance value at `date` (start-of-day). Upserts the
    /// `source: "manual"` record for that key+day, so a re-entry edits in place.
    func setManualMetric(key: String, value: Double, unit: String, date: Date) {
        ingestMetrics([IngestedMetric(metricKey: key, value: value, unit: unit, source: "manual", date: date)])
    }

    /// Remove the manual value for a key on a given day.
    func deleteManualMetric(key: String, date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        let id = "\(key):manual:\(DateFormatter.ymd.string(from: day))"
        guard let record = try? context.fetch(
            FetchDescriptor<PerformanceMetricRecord>(predicate: #Predicate { $0.id == id })
        ).first else { return }
        context.delete(record)
        try? context.save()
        markChanged()
    }

    /// Ascending manual-only points for a key — the athlete's editable entries.
    /// The date a one-time seed of an athlete constant belongs on: the earliest
    /// activity on record, so every stored workout is covered by it. `nil` when the
    /// key already has a reading — the seed is a cold start, never a correction.
    ///
    /// Dating it at "now" instead would leave every past date without the value, and
    /// `snapshot(asOf:)` resolves each threshold against the reading in force on the
    /// activity's own date — a fresh install would draw no history at all.
    func seedDate(for key: String) -> Date? {
        var readings = FetchDescriptor<PerformanceMetricRecord>(
            predicate: #Predicate { $0.metricKey == key })
        readings.fetchLimit = 1
        guard ((try? context.fetch(readings))?.isEmpty ?? true) else { return nil }
        var first = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.isCompleted },
            sortBy: [SortDescriptor(\.date, order: .forward)])
        first.fetchLimit = 1
        return (try? context.fetch(first))?.first?.date ?? Date()
    }

    func manualMetricEntries(key: String) -> [MetricPoint] {
        let records = (try? context.fetch(
            FetchDescriptor<PerformanceMetricRecord>(
                predicate: #Predicate { $0.metricKey == key && $0.source == "manual" },
                sortBy: [SortDescriptor(\.date, order: .forward)]
            )
        )) ?? []
        return records.map { MetricPoint(date: $0.date, value: $0.value) }
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
// The athlete's prompt context, stored as the rows in `CoachMemoryModels.swift` so
// it rides the same CloudKit sync. Kept here (like the ATP API) so it can reach the
// store's private `context` / `markChanged()`.
// `CoachMemory` is the façade that maps these rows to the value structs the app
// consumes; `deleteAllData()` leaves them intact. The struct↔record field mapping
// lives in the `apply`/`make` helpers, shared by the per-section savers and the
// full-restore `replaceCoachMemory`.
extension TrainingDataStore {

    // MARK: Reads

    /// The athlete profile. Defaults when no row exists.
    func coachProfile() -> UserProfile {
        guard let r = try? context.fetch(FetchDescriptor<ProfileRecord>()).first else {
            return UserProfile()
        }
        var p = UserProfile()
        p.name = r.name
        p.goals = r.goals
        p.motivation = r.motivation
        if let lat = r.latitude, let lon = r.longitude { p.coordinates = (lat, lon) }
        return p
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
        p.trainingPreferences = r.trainingPreferences
        // Pre-fold structured fields surface as plain entries; the next save
        // clears them on the row so a removed entry can't resurrect.
        p.trainingPreferences.append(contentsOf: AthletePreferences.foldLegacyFields(
            morningWorkouts: r.morningWorkouts, indoorTrainerAvailable: r.indoorTrainerAvailable,
            noSwimDays: r.noSwimDays, noBikeDays: r.noBikeDays, noRunDays: r.noRunDays))
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

    // MARK: Writes (one section each, mirroring CoachMemory's mutators)

    func saveCoachProfile(_ p: UserProfile) {
        let r = (try? context.fetch(FetchDescriptor<ProfileRecord>()).first) ?? {
            let new = ProfileRecord(); context.insert(new); return new
        }()
        Self.apply(p, to: r)
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
    func replaceCoachMemory(profile: UserProfile,
                            weeklyStructure: WeeklyStructure, preferences: AthletePreferences,
                            sportProgress: SportProgressMap, feedback: [FeedbackEntry]) {
        try? context.delete(model: ProfileRecord.self)
        try? context.delete(model: WeeklyStructureRecord.self)
        try? context.delete(model: PreferencesRecord.self)
        try? context.delete(model: SportProgressRecord.self)
        try? context.delete(model: FeedbackRecord.self)

        let pr = ProfileRecord(); Self.apply(profile, to: pr)
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

    private static func apply(_ p: UserProfile, to r: ProfileRecord) {
        r.name = p.name
        r.goals = p.goals
        r.motivation = p.motivation
        r.latitude = p.coordinates?.lat
        r.longitude = p.coordinates?.lon
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
        r.trainingPreferences = p.trainingPreferences
        // Clear the pre-fold structured fields the read path folded in — leaving
        // them set would re-append the folded entries after a removal.
        r.noSwimDays = []; r.noBikeDays = []; r.noRunDays = []
        r.morningWorkouts = nil
        r.indoorTrainerAvailable = nil
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
        r.trainingPlace = p.trainingPlace
        r.excludedAreas = p.excludedAreas
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
        p.trainingPlace = r.trainingPlace
        p.excludedAreas = r.excludedAreas
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
