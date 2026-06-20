import Foundation

// MARK: - Data Sync Coordinator
//
// GOAL.md step 2: actively synchronize the latest activities from the active
// data source (Garmin / Apple Health) into the local database on launch, then
// serve the coach's `get_activities` exclusively from that local database.
//
// The coach never reads activities live anymore — it reads what the launch sync
// (and subsequent syncs) persisted. This keeps conversations fast and offline-
// resilient, and guarantees the PMC engine and the coach see the same history.

@MainActor
final class DataSyncCoordinator {
    static let shared = DataSyncCoordinator()
    private init() {}

    private let store = TrainingDataStore.shared

    /// How many recent activities to pull per sync.
    private let syncCount = 100

    // MARK: - Sync state (last successful sync per source)

    private func lastSyncKey(_ source: DataSource) -> String {
        "trigenius.lastSync.\(source.rawValue)"
    }

    /// When `source` was last synced, or nil if never.
    func lastSync(for source: DataSource) -> Date? {
        let t = UserDefaults.standard.double(forKey: lastSyncKey(source))
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private func markSynced(_ source: DataSource, at date: Date = Date()) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastSyncKey(source))
    }

    // MARK: - Sync

    /// Pull activities from `source` into the local database. Incremental: only
    /// fetches activities since the last successful sync (inclusive of that day,
    /// so same-day activities added after the last sync are picked up). The first
    /// ever sync does a full recent backfill. Ingest upserts by id, so re-fetching
    /// the last sync day is harmless.
    /// Returns the number of activities now stored, or nil on failure.
    @discardableResult
    func sync(source: DataSource) async -> Int? {
        // Number of days back to fetch. nil = full backfill (first sync).
        let days = windowDays(since: lastSync(for: source))

        switch source {
        case .garmin:
            guard await GarminAuth.shared.isAuthenticated else { return nil }
            // getActivities ingests into the store as a side effect.
            let result = await GarminService.shared.getActivities(sport: nil, count: syncCount, days: days)
            // Only advance the watermark on success, else a network failure would
            // skip the failed window on the next (now smaller) incremental sync.
            guard !result.hasPrefix("✗") else { return nil }
            markSynced(source)
            return store.count
        case .appleHealth:
            do {
                try await HealthKitService.shared.requestAuthorization()
                let since = days.map { Calendar.current.date(byAdding: .day, value: -$0, to: Calendar.current.startOfDay(for: Date()))! }
                let workouts = try await HealthKitService.shared.fetchRecentWorkouts(count: syncCount, since: since)
                store.ingest(workouts.compactMap(Self.ingestDTO(from:)))
                markSynced(source)
                return store.count
            } catch {
                return nil
            }
        }
    }

    /// Calendar days from the last sync's start-of-day to today, or nil if never
    /// synced (→ full backfill). Day 0 (synced today) still re-fetches today.
    private func windowDays(since last: Date?) -> Int? {
        guard let last else { return nil }
        let cal = Calendar.current
        let from = cal.startOfDay(for: last)
        let to = cal.startOfDay(for: Date())
        return max(0, cal.dateComponents([.day], from: from, to: to).day ?? 0)
    }

    // MARK: - Coach read path (DB-backed)

    /// Serve `get_activities` from the local database. If the database is empty
    /// (e.g. the launch sync hasn't completed yet), sync once and retry.
    func activities(source: DataSource, sport: String?, count: Int, days: Int?) async -> String {
        var records = filtered(sport: sport, days: days)
        if records.isEmpty {
            _ = await sync(source: source)
            records = filtered(sport: sport, days: days)
        }
        let limited = Array(records.prefix(count))
        return response(for: limited, sport: sport, days: days)
    }

    // MARK: - Querying / filtering

    private func filtered(sport: String?, days: Int?) -> [ActivityRecord] {
        // Normalize the cutoff to the start of the day, otherwise `days: 1` at
        // 15:00 would drop yesterday-morning activities (cutoff "yesterday 15:00").
        // `days: 1` now means "today and yesterday", `days: 7` the last 7 days + today.
        let since = days.map {
            Calendar.current.date(byAdding: .day, value: -$0, to: Calendar.current.startOfDay(for: Date()))!
        }
        let all = store.activities(since: since)
        guard let sport, !sport.isEmpty else { return all }
        return all.filter { SportFamily.matches(storedSport: $0.sport, filter: sport) }
    }

    // MARK: - Response building

    private func response(for records: [ActivityRecord], sport: String?, days: Int?) -> String {
        let formatted: [[String: Any]] = records.compactMap { rec in
            guard let data = rec.detailsJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj
        }

        var data: [String: Any] = [
            "activities": formatted,
            "count": formatted.count,
            "summary": GarminTransform.calculateActivitySummary(formatted)
        ]
        data["filter"] = (sport != nil || days != nil) ? ["sport": sport as Any, "days": days as Any] : NSNull()

        var json = ""
        if let d = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            json = String(data: d, encoding: .utf8) ?? ""
        }
        return "✓ Retrieved \(formatted.count) \(sport ?? "all") activities (local)\n\(json)"
    }

    // MARK: - HealthKit ingest mapping

    private static func ingestDTO(from w: WorkoutSummary) -> IngestedActivity? {
        guard let date = GarminTransform.date(from: w.date) else { return nil }
        // Mirror Garmin's record keys so the shared summary/response logic works.
        let details: [String: Any] = [
            "id": w.id,
            "name": w.name,
            "date": w.date,
            "sport": w.sport,
            "duration_minutes": (w.durationMin * 10).rounded() / 10,
            "distance_km": w.distanceKm.map { ($0 * 100).rounded() / 100 } ?? NSNull(),
            "calories": w.totalEnergyKcal.map { Int($0.rounded()) } ?? NSNull(),
            "avg_hr": w.avgHRbpm.map { Int($0.rounded()) } ?? NSNull()
        ]
        let detailsJSON = (try? JSONSerialization.data(withJSONObject: details))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return IngestedActivity(
            id: "healthkit:\(w.id)",
            source: "healthkit",
            date: date,
            sport: w.sport,
            name: w.name,
            durationMinutes: w.durationMin,
            distanceKm: w.distanceKm ?? 0,
            tss: nil,   // HealthKit does not provide a TSS value.
            aerobicTE: nil,
            anaerobicTE: nil,
            detailsJSON: detailsJSON
        )
    }
}
