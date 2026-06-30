import Foundation

// MARK: - Data Sync Coordinator
//
// GOAL.md step 2: actively synchronize the latest activities from the active
// data source (Garmin / Apple Health) into the local database on launch, then
// serve the coach's `get_workouts` exclusively from that local database.
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

    /// Re-pull one source from scratch, recomputing each activity in place (`ingest`
    /// upserts by id, overwriting `detailsJSON` + TSS). Forgets the source's
    /// watermark, then: Garmin force-re-fetches its activity streams over the deep
    /// window (so cached rows pick up recomputed/new fields); Apple Health re-reads
    /// every workout fresh (re-extracting HR/power/zones). Returns the activity
    /// count, or nil on failure. Surfaced as the per-source "Re-sync" Settings action.
    @discardableResult
    func resync(source: DataSource) async -> Int? {
        UserDefaults.standard.removeObject(forKey: lastSyncKey(source))
        switch source {
        case .garmin: return await deepBackfill(source: .garmin, force: true)
        case .appleHealth: return await sync(source: .appleHealth)
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
            // Ingest the performance + wellness metric history FIRST: activity TSS is
            // scored by the store at ingest against the thresholds current on each
            // activity's own date (`snapshot(asOf:)`), so the FTP/CSS/threshold series
            // must already be present when the activities land. Non-fatal on its own.
            // Only when Garmin is the chosen metrics source — otherwise the metrics
            // come from the other provider and pulling them here would double-source.
            if AppSettings.storedMetricsSource() == .garmin {
                let metricsDays = days ?? 14   // seed ~2 weeks on a first/full sync
                if let from = Calendar.current.date(byAdding: .day, value: -metricsDays, to: Calendar.current.startOfDay(for: Date())) {
                    await syncGarminMetrics(from: from, to: Date())
                }
            }
            // getActivities ingests (and the store scores) into the store as a side effect.
            let result = await GarminService.shared.getActivities(sport: nil, count: syncCount, days: days)
            // Only advance the watermark on success, else a network failure would
            // skip the failed window on the next (now smaller) incremental sync.
            guard !result.hasPrefix("✗") else { return nil }
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
                // Ingest performance + wellness metrics before activities so the store
                // scores each activity's TSS against the thresholds current on its date.
                // Only when Apple Health is the chosen metrics source — otherwise the
                // metrics come from the other provider (avoids double-sourcing FTP,
                // sleep, etc.).
                let metricsFromHere = AppSettings.storedMetricsSource() == .appleHealth
                if metricsFromHere {
                    let metrics = (try? await HealthKitService.shared.fetchPerformanceMetrics()) ?? []
                    store.ingestMetrics(metrics)
                }
                // Build the rich per-workout record (HR/power/pace/zones), deriving HR
                // zone bounds from the athlete's thresholds as of each workout's date so
                // a power/pace-less session still scores TSS on heart rate.
                let dtos = try await HealthKitService.shared.fetchActivities(
                    count: count, since: since, history: store.performanceHistory())
                store.ingest(dtos)
                // Reconcile: remove HealthKit records no longer returned within the
                // synced window — chiefly Garmin Connect workouts now filtered out
                // at the source, which previously duplicated the Garmin data.
                store.pruneActivities(source: "healthkit", from: since ?? .distantPast, keeping: Set(dtos.map(\.id)))
                // Apple Health daily wellness (sleep / resting HR / HRV) → the same
                // `MetricKeys.wellness` series the Garmin path populates.
                if metricsFromHere {
                    let wellnessSince = since ?? Calendar.current.date(byAdding: .day, value: -30, to: Calendar.current.startOfDay(for: Date()))
                    let wellness = (try? await HealthKitService.shared.fetchWellnessMetrics(since: wellnessSince)) ?? []
                    store.ingestMetrics(wellness)
                }
                markSynced(source)
                return store.count
            } catch {
                return nil
            }
        }
    }

    /// Sync every enabled read source in turn (parallel read). Each source keeps its
    /// own watermark, so they advance independently. Garmin is skipped silently when
    /// not authenticated.
    func syncAll(_ sources: Set<DataSource>) async {
        // Sync the chosen metrics source first so the FTP/threshold series is present
        // before the *other* source's activities are scored at ingest (ingest order is
        // load-bearing — TSS is scored against the thresholds current on each date).
        let metricsSource = AppSettings.storedMetricsSource()
        let ordered = sources.sorted { a, b in
            if a == metricsSource { return true }
            if b == metricsSource { return false }
            return a.rawValue < b.rawValue
        }
        for source in ordered {
            _ = await sync(source: source)
        }
    }

    // MARK: - Deep history backfill (CTL warm-up)

    /// Pull a deep slice of history into the local database so the PMC engine's
    /// CTL (Fitness, 42-day EWMA) has a proper >42-day warm-up. Garmin only — the
    /// Apple Health sync already backfills generously on its first run. Returns
    /// the number of activities ingested, or nil if unavailable / failed.
    /// `force` re-fetches every activity in the window (ignoring the per-activity
    /// cache) and recomputes its TSS + distance — used by the "recompute all" action
    /// so existing activities pick up newly-computed fields (normalized pace, swim
    /// length cleaning). Manual distance overrides are preserved.
    @discardableResult
    func deepBackfill(source: DataSource, days: Int = 240, force: Bool = false) async -> Int? {
        guard source == .garmin, await GarminAuth.shared.isAuthenticated else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let from = cal.date(byAdding: .day, value: -days, to: today) else { return nil }
        // Backfill the full window's wellness + historical performance series FIRST
        // — both the primary path that populates deep marker/recovery history AND the
        // prerequisite for as-of-date TSS scoring of the activities ingested next
        // (each scored against the FTP/threshold current on its own date). Skipped when
        // Garmin isn't the chosen metrics source — those markers come from the other
        // provider then, and activities are scored against whatever it already ingested.
        if AppSettings.storedMetricsSource() == .garmin {
            await syncGarminMetrics(from: from, to: today)
        }
        let count = await GarminService.shared.backfillActivities(
            startDate: DateFormatter.ymd.string(from: from),
            endDate: DateFormatter.ymd.string(from: today),
            force: force
        )
        if count != nil { markSynced(source) }
        return count
    }

    // MARK: - Garmin metric-history sync (wellness + performance + zones)

    /// Pull the wellness (sleep/rHR/HRV) + historical performance (FTP, VO2max,
    /// thresholds, CSS, weight) time series and the training zones for `[from, to]`
    /// into the DB. Best-effort and idempotent (upsert by metric+source+day, so
    /// re-syncing a window only updates — "written only if not already present").
    /// Returns the `syncUserSettings` summary line for the `sync_user_settings` tool.
    @discardableResult
    private func syncGarminMetrics(from: Date, to: Date) async -> String {
        let start = DateFormatter.ymd.string(from: from)
        let end = DateFormatter.ymd.string(from: to)
        let history = await GarminService.shared.fetchMetricHistory(startDate: start, endDate: end)
        if !history.isEmpty { store.ingestMetrics(history) }
        // Training zones + max HR are the only markers the range endpoints don't
        // cover (see GarminService.syncUserSettings).
        let (text, settings) = await GarminService.shared.syncUserSettings()
        if let settings {
            store.ingestMetrics(Self.metrics(fromGarminSettings: settings, date: Date()))
        }
        return text
    }

    /// Manual full metric refresh for the `sync_user_settings` coach tool: pulls a
    /// recent window of wellness + historical-performance history and the training
    /// zones into the store. Returns a summary string for the coach.
    func refreshGarminMetrics(days: Int = 30) async -> String {
        let today = Date()
        guard let from = Calendar.current.date(byAdding: .day, value: -days, to: Calendar.current.startOfDay(for: today)) else {
            return "✗ Error: could not compute the sync window."
        }
        return await syncGarminMetrics(from: from, to: today)
    }

    // MARK: - Coach read path — health metrics (DB-backed, source-agnostic)

    /// Serve `get_health_metrics` from the local wellness time series
    /// (`resting_hr` / `hrv_overnight` / `sleep_*`), merged across every enabled read
    /// source. If the window holds no wellness rows, sync the enabled sources once and
    /// retry so a first conversation still sees recovery data.
    func healthMetrics(days: Int) async -> String {
        let n = max(1, min(days, 30))
        if !hasWellnessRows(days: n) {
            await syncAll(AppSettings.storedReadSources())
        }
        return healthMetricsResponse(days: n)
    }

    /// Latest-`days` start-of-day → value map for one wellness metric key.
    private func wellnessByDay(_ key: String, days: Int) -> [Date: Double] {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date()))!
        var out: [Date: Double] = [:]
        for p in store.metricHistory(key) where p.date >= cutoff {
            out[cal.startOfDay(for: p.date)] = p.value
        }
        return out
    }

    private func hasWellnessRows(days: Int) -> Bool {
        MetricKeys.wellness.contains { !wellnessByDay($0, days: days).isEmpty }
    }

    private func healthMetricsResponse(days: Int) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let rhr = wellnessByDay("resting_hr", days: days)
        let hrv = wellnessByDay("hrv_overnight", days: days)
        let score = wellnessByDay("sleep_score", days: days)
        let dur = wellnessByDay("sleep_duration_h", days: days)
        let deep = wellnessByDay("sleep_deep_h", days: days)
        let rem = wellnessByDay("sleep_rem_h", days: days)
        func hours(_ v: Double?) -> Any { v.map { ($0 * 10).rounded() / 10 } ?? NSNull() }
        func intOrNull(_ v: Double?) -> Any { v.map { Int($0.rounded()) } ?? NSNull() }

        var daily: [[String: Any]] = []
        for offset in 0..<days {
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            var entry: [String: Any] = ["date": DateFormatter.ymd.string(from: day)]
            entry["resting_hr"] = intOrNull(rhr[day])
            entry["hrv_overnight"] = intOrNull(hrv[day])
            if let s = score[day] {
                entry["sleep"] = [
                    "score": Int(s.rounded()),
                    "duration_hours": hours(dur[day]),
                    "deep_hours": hours(deep[day]),
                    "rem_hours": hours(rem[day]),
                ]
            } else { entry["sleep"] = NSNull() }
            daily.append(entry)
        }

        func avg(_ vals: [Double], _ places: Int) -> Any {
            guard !vals.isEmpty else { return NSNull() }
            let a = vals.reduce(0, +) / Double(vals.count)
            let f = pow(10.0, Double(places))
            return (a * f).rounded() / f
        }
        // Newest-first resting HR for the trend (matches GarminTransform.analyzeTrend).
        let restingHRs = (0..<days).compactMap { rhr[cal.date(byAdding: .day, value: -$0, to: today)!] }
        let summary: [String: Any] = [
            "avg_resting_hr": avg(restingHRs, 0),
            "avg_hrv_overnight": avg(Array(hrv.values), 0),
            "avg_sleep_score": avg(Array(score.values), 1),
            "avg_sleep_hours": avg(Array(dur.values), 1),
            "resting_hr_trend": restingHRs.isEmpty ? "Unknown" : GarminTransform.analyzeTrend(restingHRs),
        ]
        let data: [String: Any] = [
            "period": ["start": DateFormatter.ymd.string(from: cal.date(byAdding: .day, value: -(days - 1), to: today)!),
                       "end": DateFormatter.ymd.string(from: today), "days": days],
            "daily_metrics": daily,
            "summary": summary,
        ]
        let json = String(compactJSON: data)
        return "✓ Retrieved health metrics for the last \(days) days (local)\n\(json)"
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
        // A failed fetch returns "✗ …"; feeding that to replaceScheduled would wipe
        // the local mirror to match an empty result, so bail before touching it.
        guard !result.hasPrefix("✗"), let scheduled = Self.parseScheduledWorkouts(result) else { return }
        // Detect TriGenius plans the athlete deleted on Garmin's side: a local plan
        // whose recorded Garmin id is no longer in the calendar. Clear the dead ref so
        // the write-target reconcile re-creates it (local plans are authoritative).
        let presentGarminIds = Set(scheduled.compactMap { $0["workout_id"].map { "\($0)" } })
        store.clearStaleWriteRefs(target: "garmin", present: presentGarminIds, from: from, to: to)
        let thresholds = store.latestSnapshot()
        // Skip Garmin workouts that are TriGenius's own local plans pushed to Garmin —
        // they already exist locally (as `local:` rows referencing this Garmin id), so
        // re-mirroring them as separate `garmin:` rows would duplicate them.
        let ownPushed = store.externalRefIds(target: "garmin", source: "local")
        let planned = scheduled
            .filter { item in
                guard let wid = item["workout_id"] else { return true }
                return !ownPushed.contains("\(wid)")
            }
            .compactMap { Self.scheduledDTO(from: $0, thresholds: thresholds) }
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
        let steps = data["steps"] as? [[String: Any]] ?? []
        // Intensity-based planned TSS from the workout's structured steps; nil falls
        // back to the duration heuristic at read time.
        let targetTSS = PlannedTSS.estimate(
            compactSteps: steps,
            family: SportFamily(sportKey: sport),
            thresholds: thresholds
        )
        // Persist the structure verbatim so the UI can render it (see
        // `WorkoutRecord.stepsJSON`). No extra API calls — these steps were
        // already fetched for the TSS estimate above.
        let stepsJSON = (try? JSONSerialization.data(withJSONObject: steps))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return IngestedScheduledWorkout(
            id: id,
            source: "garmin",
            date: date,
            sport: sport,
            name: data["name"] as? String ?? "Scheduled Workout",
            targetDurationMinutes: (data["duration_minutes"] as? NSNumber)?.doubleValue ?? 0,
            targetDistanceMeters: (data["distance_meters"] as? NSNumber)?.doubleValue ?? 0,
            targetTSS: targetTSS,
            notes: data["description"] as? String ?? "",
            stepsJSON: stepsJSON,
            poolLengthMeters: Coerce.double(data["pool_length"]).flatMap { $0 > 0 ? $0 : nil },
            associatedActivityId: item["associated_activity_id"].map { "\($0)" }
        )
    }

    // MARK: - Garmin settings → performance metrics

    /// Map the dict returned by `GarminService.syncUserSettings()` into time-series
    /// metric records. Scoped to what the range endpoints don't provide — max HR
    /// and the HR/power zones; the FTP/VO2max/threshold/CSS/weight series come from
    /// `GarminService.fetchMetricHistory`. Shared by the launch/dashboard sync and
    /// the `sync_user_settings` coach tool so both ingest the same way.
    static func metrics(fromGarminSettings settings: [String: Any], date: Date) -> [IngestedMetric] {
        var out: [IngestedMetric] = []
        if let maxHR = (settings["max_hr"] as? NSNumber)?.doubleValue, maxHR > 0 {
            out.append(IngestedMetric(metricKey: "max_hr", value: maxHR, unit: "bpm", source: "garmin", date: date))
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
        // CSS is stored as raw speed (m/s); convert the profile's "m:ss"/100m pace.
        if let css = p.cssPace, let secs = paceSeconds(from: css), secs > 0 {
            out.append(IngestedMetric(metricKey: "swim_css_speed", value: 100.0 / secs, unit: "m_per_s", source: "manual", date: date))
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

    // MARK: - Coach read path — unified workouts (planned + completed, local)

    /// Serve the unified `get_workouts` from the local store. `status` selects the
    /// sections (`planned` open plans / `completed` finished activities / both), so
    /// completed rows never arrive via two tools. Completed rows are projected to the
    /// lean, TSS-focused view (`CoachActivityProjection`); `detailed` expands them to
    /// the per-lap breakdown, capped to 5. Each planned row carries its `workout_id`
    /// + a ready-to-reuse `workout_data` for modify/move/delete. Source-agnostic.
    func workouts(status: String, sport: String?, from: Date?, to: Date?, limit: Int, detailed: Bool) async -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let wantPlanned = status != "completed"
        let wantCompleted = status != "planned"
        let start = from ?? cal.date(byAdding: .day, value: -14, to: today)!
        let end = to ?? cal.date(byAdding: .day, value: wantPlanned ? 28 : 0, to: today)!
        let cap = max(detailed ? min(limit, 5) : limit, 0)

        var data: [String: Any] = [
            "range": ["start": DateFormatter.ymd.string(from: start),
                      "end": DateFormatter.ymd.string(from: max(start, end))]
        ]
        var counts: [String] = []

        if wantCompleted {
            var completed = bySport(store.activities(from: start, to: end), sport)
            if completed.isEmpty, store.activities(since: nil).isEmpty {
                // First launch: the DB can be empty before the initial sync lands.
                await syncAll(AppSettings.storedReadSources())
                completed = bySport(store.activities(from: start, to: end), sport)
            }
            let rows = completed.prefix(cap).map { completedRow($0, detailed: detailed) }
            data["completed"] = rows
            counts.append("\(rows.count) completed")
        }
        if wantPlanned {
            let rows = bySport(store.openScheduledWorkouts(from: start, to: end), sport)
                .prefix(cap).map(plannedRow)
            data["planned"] = rows
            counts.append("\(rows.count) planned")
        }
        return "✓ Retrieved \(counts.joined(separator: " + ")) workouts (local)\n\(String(compactJSON: data))"
    }

    private func bySport(_ records: [WorkoutRecord], _ sport: String?) -> [WorkoutRecord] {
        guard let sport, !sport.isEmpty else { return records }
        return records.filter { SportFamily.matches(storedSport: $0.sport, filter: sport) }
    }

    private func completedRow(_ rec: WorkoutRecord, detailed: Bool) -> [String: Any] {
        let details = (rec.detailsJSON.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        return detailed
            ? CoachActivityProjection.detail(details, tss: rec.tss, tssBasis: rec.tssBasis)
            : CoachActivityProjection.summary(details, tss: rec.tss, tssBasis: rec.tssBasis)
    }

    private func plannedRow(_ rec: WorkoutRecord) -> [String: Any] {
        [
            "workout_id": rec.id,
            "date": DateFormatter.ymd.string(from: rec.date),
            "sport": rec.sport,
            "workout_data": WorkoutPayloadBuilder.workoutData(from: rec)
        ]
    }

    // MARK: - Write-target reconciliation (no plan lost on target switch)

    /// Push every open future plan that the (newly selected) `target` hasn't seen yet
    /// onto it, recording the returned external id. Called on launch and whenever the
    /// write target changes, so switching targets never loses an upcoming plan.
    func reconcileWriteTarget(_ target: WriteTarget) async {
        let syncTarget = WorkoutTargetFactory.make(target)
        guard await syncTarget.isAvailable else { return }
        for plan in store.plansMissingRef(target: target.refKey, from: Date()) {
            let payload = PlannedWorkout(
                workoutData: WorkoutPayloadBuilder.workoutData(from: plan),
                date: DateFormatter.ymd.string(from: plan.date)
            )
            let result = await syncTarget.schedule(payload)
            if result.success, let ext = result.externalId {
                store.setExternalRef(id: plan.id, target: target.refKey, externalId: ext)
            }
        }
        // Push first so re-created plans are in the live set, then drop whatever the
        // target still holds for a plan that's gone (deleted outside `deletePlan`, or
        // a ref lost to a store reset) — the watch otherwise keeps stale workouts.
        await syncTarget.prune(keeping: store.liveExternalRefIds(target: target.refKey))
    }

    // MARK: - Plan deletion (local + every provider it reached)

    /// Delete a planned workout locally and from *every* write target it was pushed
    /// to — not just the active one. A plan pushed to Garmin while the write target
    /// is now the Apple Watch would otherwise be orphaned on Garmin. Resolves each
    /// target's external id the same way the scheduling handler does (an explicit
    /// `externalRefs` entry, or the raw provider id when the plan originated there).
    func deletePlan(id: String) async {
        if let rec = store.scheduledWorkout(id: id) {
            for wt in WriteTarget.allCases {
                let ext = rec.externalRefs[wt.refKey]
                    ?? (rec.source == wt.refKey ? TrainingDataStore.rawId(rec.id) : nil)
                guard let ext else { continue }
                _ = await WorkoutTargetFactory.make(wt).delete(externalId: ext)
            }
        }
        store.deleteScheduledWorkout(id: id)
    }

}
