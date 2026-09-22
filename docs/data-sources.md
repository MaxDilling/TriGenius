# Data sources & write targets

Detail doc for `DataManagement/HealthKit/`, `DataManagement/Garmin/`, `DataManagement/Workouts/`, and `ref/`. Index: `CLAUDE.md` → Components.

## HealthKit (`HealthKit/HealthKitService.swift`)

Read-only Apple Health: workouts, performance markers (FTP/VO2max/weight), daily wellness (`fetchWellnessMetrics`). Per-workout records mirror the Garmin schema — `normalizedRecord(for:)` writes the same `detailsJSON` keys the detail view and `TLCalculator` consume, and returns the `ZoneSamples` the store buckets into time-in-zone.

- **Run normalized pace is grade-adjusted (true NGP)**: `speedStream` attaches GPS-route gradient to each running sample and defers to `GradeAdjustedPace`/`NormalizedStream`; indoor runs reduce to plain normalized speed.
- **Time-in-zone is not read from Apple Health** (it doesn't expose one) *and not computed here*: the service hands over the raw HR / power / grade-adjusted-speed streams as `ZoneSamples` and the store buckets them at ingest. Power and pace carry HealthKit's own per-reading interval; the HR point stream is gap-weighted by `ZoneBucketing.durationSamples`.
- The HR stream comes from `HKQuantitySeriesSampleQuery` (≈1 s), not the ≈2.5 min aggregated samples.
- Dedup is deterministic: `isGarmin(_:)` drops any workout authored by Garmin Connect, so a Garmin session mirrored into Apple Health is never double-counted.
- **Multisport** (`.swimBikeRun`): `HKWorkout.workoutActivities` are the legs. `normalizedRecord(for:activity:)` takes an optional activity and runs its *whole existing body* against a `SampleScope` — the leg's own date window, statistics provider and distance type — so a leg produces the record it would as a standalone workout. Gotcha: HealthKit associates every sample with the **parent** workout, so `predicateForObjects(from:)` can't narrow a leg; `SampleScope.objectPredicate` is nil for a leg and every query falls to its date range.

## Garmin (`DataManagement/Garmin/`)

Layered, reads and writes: `GarminAuth` (SSO/MFA → OAuth; the one `actor` here, guarding token/MFA state), `GarminClient` (low-level connectapi), `GarminService` (high-level orchestration, ToolResult-style JSON), `GarminTransformations` (pure response-shaping), `GarminWorkoutBuilder`, `GarminMappings`.

**Concurrency gotcha:** `GarminClient`/`GarminService` are `nonisolated final class: Sendable`, deliberately **not actors** — they hold no mutable state (only `GarminClient`'s display-name cache, guarded by a `Mutex`), so the raw `[String: Any]`/`Any?` JSON they pass between each other never crosses an isolation boundary (which Swift 6 non-Sendable rules would forbid). Only values handed to a MainActor caller cross a boundary — hence the `sending` results on `GarminService.speedStreamDiagnostics`/`syncUserSettings`. Task groups still require **Sendable** child results, so JSON crosses those as strings via `GarminService.jsonString`/`jsonArray`.

**Multisport** — Garmin files each leg *and each transition* of a triathlon as its own activity, but the activity list returns only the parent, flagged `parent: true` with **no child ids**. `multisportSegments` therefore fetches the parent's own DTO (`GarminClient.getActivity(id:)`) for `metadataDTO.childIds`, then runs each child back through `formatActivityRecord` unchanged. Two gotchas:
- The `/activity/{id}` DTO nests its summary in `summaryDTO` and spells keys differently from a list entry (`averagePower` vs `avgPower`, `normalizedPower` vs `normPower`, `averageRunCadence` vs `averageRunningCadenceInStepsPerMinute`). `GarminTransform.flattenActivity` is the pure renaming shim; without it the bike leg silently loses its normalized power.
- Leg offsets come from the GMT start deltas (`GarminTransform.timestamp`), which is the same clock `metricSamples` uses for its stream offsets — so the parent's single stream slices per leg. Children's own streams are fetched (they feed each leg's NGP / power curve) but not stored again. Captured payloads: `ref/garmin_api/multisportParent.json`, `multisportChild_bike.json`, `triathlonDetails`.

**Time-in-zone is computed locally, not read from Garmin.** The activity payload carries server-computed `hrTimeInZone_*` / `powerTimeInZone_*`, bucketed against the athlete's *Garmin Connect* zone configuration — an unknown model that would disagree with the Apple Health path on the same workout. `formatActivityRecord` therefore ignores them and hands the `directHeartRate`/`directPower` streams and `GarminTransform.gradeAdjustedSamples` (the same NGP input) over as `ZoneSamples` for the store to bucket. All three go through `ZoneBucketing.durationSamples`, so every stream off one activity carries the same clock — the detail rows are ~1 s apart but jump across pauses, and a fixed second per sample would make one stream run slow against the others. `syncUserSettings` still *reports* Garmin's configured zones — that is display of the athlete's device setup, not an input to any computation.

**Metric history** — `GarminService.fetchMetricHistory` runs one concurrent *range* call per metric type (HRV, sleep + resting HR, weight, VO2max, FTP/CSS/threshold), parsed by `GarminTransform.parse*` into dated `IngestedMetric`s. Gotcha: the sleep-stats endpoint caps each request at **28 days** (`BadRequestException: Exceeded max number of days`), so `fetchSleepStats` splits into ≤28-day chunks, fetches concurrently, merges before parsing — without it a deep backfill silently drops the whole sleep/resting-HR series. Range failures log via `os.Logger` (`subsystem: net.Narica.TriGenius, category: Garmin`) — a capped endpoint that is not chunked therefore leaves its metric silently un-backfilled, so the log is the place to check after widening the window. A deep backfill / re-sync spans `DataSyncCoordinator.deepHistoryDays` (a year): enough to fill the charts' 1Y range and to resolve both threshold estimates off a complete history. `syncUserSettings` covers what ranges don't (HR zones, max HR, power zones from current FTP). **Max HR is seeded once, not synced.** It is an athlete constant and the dominant input to every threshold estimate (4 bpm is worth up to 10 s/km of LT pace), so `metrics(fromGarminSettings:date:maxHRSeed:)` writes it only when the store holds no reading, as `source: "manual"` — which outranks every synced source, so an athlete's correction survives the next sync instead of being overwritten by whatever the watch still has configured. The seed is dated at the **earliest stored activity** (`TrainingDataStore.seedDate(for:)`), not at today: `snapshot(asOf:)` resolves each threshold against the reading in force on the activity's own date, so a seed dated now would leave a fresh install with no history at all. Apple Health is deliberately not a source for it — the only HRmax it carries is the highest recorded second, which both labs measure as 7–19 bpm wrong.

## Write targets (`DataManagement/Workouts/`)

`WorkoutSyncTarget` is the seam for "where planned workouts go": `schedule/update/move/delete` a `PlannedWorkout` → a `WorkoutWriteResult` with the provider's external id. `WorkoutTargetFactory.make(_:)` builds the active one.

- **`GarminWorkoutTarget`** — thin adapter over `GarminService` + `GarminWorkoutBuilder`.
- **`AppleWatchWorkoutTarget`** (iOS-only, `#if os(iOS)`) — WorkoutKit. `AppleWatchWorkoutBuilder` translates the canonical compact steps into a `CustomWorkout` (swim/bike/run only — others → nil). Gotcha: `CustomWorkout`'s initializer **traps** on anything it rejects, so the builder gates on `CustomWorkout.supportsActivity`/`supportsAlert`, dropping an alert the activity can't carry (e.g. pace on a swim) while keeping goal + interval structure. External ref is the `WorkoutPlan` UUID. macOS uses `UnavailableWorkoutTarget`.
- **`WorkoutPayloadBuilder`** reconstructs `workout_data` from a stored plan, so any plan re-materializes for any target from the local source of truth.

## Calendar (`DataManagement/Calendar/CalendarService.swift`)

Read-only EventKit wrapper; a cross-cutting always-available source that lets the coach plan around busy days.

## Reference material (`ref/`)

None of it is in the build — **never import or ship it**; port behavior into Swift.

- `ref/garmin_health_data/` — vendored Python Garmin Connect client; the worked example for endpoint URLs, response shapes, token exchange (start with `garmin_client/api.py`, `constants.py`, `client.py`).
- `ref/garmin_api/` — captured raw Garmin API responses (e.g. `swimDetails`) for exact payload shapes.
- `ref/testdata/` — 6 months of real Garmin data: `garmin_data.db` (read-only, the lab's input) + exported `garmin_files/`. Plus `ref/workout_garmin_*.json` / `ref/workout_healthkit_*.json` for comparing the two source schemas.
- `ref/tss_lab/` — Python sandbox for designing and **validating** TL/PMC algorithms against `testdata/` before hand-porting to Swift (`harness.py` → validation report/plots; `pytest` regression gates; `PORTING.md` tracks what's ported). The `Analytics/` formulas should match it.
- `ref/TrainingPeak Screenshots/` — TrainingPeaks UI/behavior reference (e.g. `ATP/` for the annual plan, weekly-TL and CL flows).
- `ref/knowlage/` — background research notes behind the in-app knowledge base.
