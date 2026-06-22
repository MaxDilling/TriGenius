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

    /// Forget the last-sync watermark for every source so the next sync does a
    /// full backfill. Pairs with wiping the local database.
    func resetSyncState() {
        for source in DataSource.allCases {
            UserDefaults.standard.removeObject(forKey: lastSyncKey(source))
        }
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
            // Pull performance metrics (FTP, CSS, LTHR, VO2max…) into the DB time
            // series alongside activities. Failure here is non-fatal to the sync.
            let (_, settings) = await GarminService.shared.syncUserSettings()
            if let settings {
                store.ingestMetrics(Self.metrics(fromGarminSettings: settings, date: Date()))
            }
            // Mirror planned calendar workouts into the local scheduled store so
            // the dashboard Agenda, calendar screen and weekly targets reflect them.
            await syncScheduledWorkouts(source: .garmin)
            markSynced(source)
            return store.count
        case .appleHealth:
            do {
                try await HealthKitService.shared.requestAuthorization()
                let since = days.map { Calendar.current.date(byAdding: .day, value: -$0, to: Calendar.current.startOfDay(for: Date()))! }
                // On a full backfill, fetch generously so the reconcile below has
                // the complete keep-set and doesn't drop legitimate older records.
                let count = since == nil ? max(syncCount, 1000) : syncCount
                let workouts = try await HealthKitService.shared.fetchRecentWorkouts(count: count, since: since)
                let dtos = workouts.compactMap(Self.ingestDTO(from:))
                store.ingest(dtos)
                // Reconcile: remove HealthKit records no longer returned within the
                // synced window — chiefly Garmin Connect workouts now filtered out
                // at the source, which previously duplicated the Garmin data.
                store.pruneActivities(source: "healthkit", from: since ?? .distantPast, keeping: Set(dtos.map(\.id)))
                let metrics = (try? await HealthKitService.shared.fetchPerformanceMetrics()) ?? []
                store.ingestMetrics(metrics)
                markSynced(source)
                return store.count
            } catch {
                return nil
            }
        }
    }

    // MARK: - Deep history backfill (CTL warm-up)

    /// Pull a deep slice of history into the local database so the PMC engine's
    /// CTL (Fitness, 42-day EWMA) has a proper >42-day warm-up. Garmin only — the
    /// Apple Health sync already backfills generously on its first run. Returns
    /// the number of activities ingested, or nil if unavailable / failed.
    @discardableResult
    func deepBackfill(source: DataSource, days: Int = 240) async -> Int? {
        guard source == .garmin, await GarminAuth.shared.isAuthenticated else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let from = cal.date(byAdding: .day, value: -days, to: today) else { return nil }
        let count = await GarminService.shared.backfillActivities(
            startDate: DateFormatter.ymd.string(from: from),
            endDate: DateFormatter.ymd.string(from: today)
        )
        if count != nil { markSynced(source) }
        return count
    }

    // MARK: - Scheduled-workout sync (planned calendar items)

    /// Window the scheduled-workout mirror covers: a week back through four weeks
    /// ahead of today. A week back keeps recently-passed planned sessions visible.
    private static let scheduledLookbackDays = 7
    private static let scheduledLookaheadDays = 28

    /// Pull PLANNED workouts from the active source's calendar into the local
    /// scheduled-workout store, replacing that source's items in the window so
    /// device-side deletions are reflected. Best-effort: a no-op for sources
    /// without a calendar (Apple Health) or when Garmin isn't authenticated.
    func syncScheduledWorkouts(source: DataSource) async {
        guard source == .garmin, await GarminAuth.shared.isAuthenticated else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let from = cal.date(byAdding: .day, value: -Self.scheduledLookbackDays, to: today),
              let to = cal.date(byAdding: .day, value: Self.scheduledLookaheadDays, to: today) else { return }
        let result = await GarminService.shared.getWorkouts(
            startDate: DateFormatter.ymd.string(from: from),
            endDate: DateFormatter.ymd.string(from: to)
        )
        guard let scheduled = Self.parseScheduledWorkouts(result) else { return }
        let thresholds = store.latestSnapshot()
        let planned = scheduled.compactMap { Self.scheduledDTO(from: $0, thresholds: thresholds) }
        store.replaceScheduled(source: "garmin", from: from, to: to, with: planned)
    }

    /// Extract the `scheduled` array from `getWorkouts`'s "✓ …\n<json>" output.
    private static func parseScheduledWorkouts(_ result: String) -> [[String: Any]]? {
        guard let brace = result.firstIndex(of: "{") else { return nil }
        let json = String(result[brace...])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scheduled = obj["scheduled"] as? [[String: Any]] else { return nil }
        return scheduled
    }

    /// Map a `getWorkouts` scheduled item to a scheduled-workout DTO. The editable
    /// content lives under `workout_data` (completed activities are in a separate
    /// array and never reach here).
    private static func scheduledDTO(from item: [String: Any], thresholds: PerformanceSnapshot) -> IngestedScheduledWorkout? {
        guard let dateStr = item["date"] as? String, let date = DateFormatter.ymd.date(from: dateStr) else { return nil }
        let id = item["workout_id"].map { "garmin:\($0)" } ?? "garmin:\(dateStr)"
        let data = item["workout_data"] as? [String: Any] ?? [:]
        let sport = data["sport"] as? String ?? "other"
        // Intensity-based planned TSS from the workout's structured steps; nil falls
        // back to the duration heuristic at read time.
        let targetTSS = PlannedTSS.estimate(
            compactSteps: data["steps"] as? [[String: Any]] ?? [],
            family: SportFamily(sportKey: sport),
            thresholds: thresholds
        )
        return IngestedScheduledWorkout(
            id: id,
            source: "garmin",
            date: date,
            sport: sport,
            name: data["name"] as? String ?? "Scheduled Workout",
            targetDurationMinutes: (data["duration_minutes"] as? NSNumber)?.doubleValue ?? 0,
            targetTSS: targetTSS,
            notes: data["description"] as? String ?? "",
            associatedActivityId: item["associated_activity_id"].map { "\($0)" }
        )
    }

    // MARK: - Garmin settings → performance metrics

    /// Map the dict returned by `GarminService.syncUserSettings()` into time-series
    /// metric records. Shared by the launch/dashboard sync and the
    /// `sync_user_settings` coach tool so both ingest the same way.
    static func metrics(fromGarminSettings settings: [String: Any], date: Date) -> [IngestedMetric] {
        var out: [IngestedMetric] = []
        func add(_ key: String, _ value: Double?, _ unit: String) {
            guard let value, value > 0 else { return }
            out.append(IngestedMetric(metricKey: key, value: value, unit: unit, source: "garmin", date: date))
        }
        add("cycling_ftp", (settings["cycling_ftp"] as? NSNumber)?.doubleValue, "watts")
        add("running_ftp", (settings["running_ftp"] as? NSNumber)?.doubleValue, "watts")
        add("lactate_threshold_hr", (settings["lactate_threshold_hr"] as? NSNumber)?.doubleValue, "bpm")
        add("max_hr", (settings["max_hr"] as? NSNumber)?.doubleValue, "bpm")
        add("vo2max_running", (settings["vo2max_running"] as? NSNumber)?.doubleValue, "ml_kg_min")
        add("vo2max_cycling", (settings["vo2max_cycling"] as? NSNumber)?.doubleValue, "ml_kg_min")
        add("weight_kg", (settings["weight_kg"] as? NSNumber)?.doubleValue, "kg")
        if let css = settings["css_pace_per_100m"] as? String, let secs = paceSeconds(from: css) {
            add("swim_css_pace", secs, "sec_per_100m")
        }
        if let pace = settings["lactate_threshold_pace"] as? String, let secs = paceSeconds(from: pace) {
            add("lactate_threshold_pace", secs, "sec_per_km")
        }
        out += zoneMetrics(settings["hr_zones"], prefix: "hr_zone", unit: "bpm", source: "garmin", date: date)
        out += zoneMetrics(settings["power_zones"], prefix: "power_zone", unit: "watts", source: "garmin", date: date)
        return out
    }

    /// Map the legacy/exported profile scalars (FTP, CSS, VO2max, lactate-threshold
    /// HR, max HR, weight, HR/power zones) into time-series metric records. Shared by
    /// the one-time `coach_memory.json` migration (`TriGeniusApp.seedPerformanceMetricsIfNeeded`)
    /// and the manual JSON import. Marked `source: "manual"` — these are athlete-supplied.
    static func metrics(fromProfile p: UserProfile, date: Date) -> [IngestedMetric] {
        var out: [IngestedMetric] = []
        if let ftp = p.ftp {
            out.append(IngestedMetric(metricKey: "cycling_ftp", value: Double(ftp), unit: "watts", source: "manual", date: date))
        }
        if let css = p.cssPace, let secs = paceSeconds(from: css) {
            out.append(IngestedMetric(metricKey: "swim_css_pace", value: secs, unit: "sec_per_100m", source: "manual", date: date))
        }
        if let vo2 = p.vo2max {
            out.append(IngestedMetric(metricKey: "vo2max_running", value: vo2, unit: "ml_kg_min", source: "manual", date: date))
        }
        if let lthr = p.lactateThrHR {
            out.append(IngestedMetric(metricKey: "lactate_threshold_hr", value: Double(lthr), unit: "bpm", source: "manual", date: date))
        }
        if let maxHR = p.maxHR {
            out.append(IngestedMetric(metricKey: "max_hr", value: Double(maxHR), unit: "bpm", source: "manual", date: date))
        }
        if let weight = p.weightKg {
            out.append(IngestedMetric(metricKey: "weight_kg", value: weight, unit: "kg", source: "manual", date: date))
        }
        out += zoneMetrics(p.zones["hr_zones"], prefix: "hr_zone", unit: "bpm", source: "manual", date: date)
        out += zoneMetrics(p.zones["power_zones"], prefix: "power_zone", unit: "watts", source: "manual", date: date)
        return out
    }

    /// Parse a "m:ss" pace string into seconds (inverse of `GarminTransform.speedToPace`).
    static func paceSeconds(from pace: String) -> Double? {
        let parts = pace.split(separator: ":")
        guard parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]) else { return nil }
        return Double(m * 60 + s)
    }

    /// Decompose a zone dict (`["z1": [lo, hi], … "z5": [lo, hi]]`) into one
    /// numeric metric per zone upper bound (`<prefix>1_upper` … `<prefix>5_upper`),
    /// so each boundary becomes a chartable time series. The lower bound of zone N
    /// equals the upper of zone N-1 (zone 1's lower is 0), so storing uppers is
    /// lossless. Shared by Garmin sync and the one-time migration.
    static func zoneMetrics(_ zones: Any?, prefix: String, unit: String, source: String, date: Date) -> [IngestedMetric] {
        guard let zones = zones as? [String: Any] else { return [] }
        var out: [IngestedMetric] = []
        for n in 1...5 {
            guard let bounds = zones["z\(n)"] as? [Any], bounds.count >= 2,
                  let upper = (bounds[1] as? NSNumber)?.doubleValue, upper > 0 else { continue }
            out.append(IngestedMetric(metricKey: "\(prefix)\(n)_upper", value: upper, unit: unit, source: source, date: date))
        }
        return out
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

        let json = String(prettyJSON: data)
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
