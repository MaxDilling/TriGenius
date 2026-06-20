import Foundation
import SwiftData

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

/// One day's aggregated TSS — the unit the PMC engine works on.
struct DailyTSS: Sendable, Identifiable {
    let date: Date
    let totalTSS: Double
    var id: Date { date }
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
            container = try ModelContainer(for: ActivityRecord.self)
        } catch {
            // An in-memory fallback keeps the app usable even if the on-disk
            // store can't be opened (e.g. an incompatible migration).
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: ActivityRecord.self, configurations: config)
        }
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
}
