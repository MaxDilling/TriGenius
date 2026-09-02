# Local store & sync

Detail doc for `DataManagement/Local/`, the persistence layers, and CloudKit. Index: `CLAUDE.md` → Data flow.

## `WorkoutRecord` — the unified slot

A TrainingPeaks-style row with an optional **planned** section (targets + structured `stepsJSON`) and an optional **completed** section; `isPlanned`/`isCompleted` flag which are present, `externalRefsJSON` maps each write target → provider id.

Completed section carries the finished activity + TL plus:
- `tlBasis` — provenance label of how that TL was derived, so a HR-zone-fallback score isn't over-trusted.
- `powerCurveJSON` — the ride's max-mean power curve, computed at ingest from the raw power stream via `PowerCurve`.
- `streamsData` — downsampled metric streams (HR/power/speed/cadence/elevation, ~600 uniform bins, lzfse-compressed values-only JSON via `WorkoutStreams`, ~2–3 KB), computed at ingest from the same source-shaped samples and rendered by the detail view's `WorkoutStreamChart`s.
- `segmentsJSON` — the **legs of a multisport session** (`WorkoutSegments`), "" for a single-sport row. See below.

### Multisport segments

A triathlon or brick is **one row** (`sport: "multi_sport"`) whose legs live in `segmentsJSON`: an ordered `[{offset_s, source_id, tss, tss_basis, details, streams}]`. Each leg's `details` is shaped **exactly like a single-sport row's `detailsJSON`** — that identity is the whole design: `TSSScoring.score`, `ZoneDistribution.zoneSeconds` and the detail view's metric rows run unchanged on a leg, so the bike leg scores power TL and the run leg rTL with no parallel implementation. A transition carries duration only; nothing is substituted for the intensity it never measured.

Consequences every reader must respect:
- **Row `tss`/`distanceKm` are the sum over the legs** (`TSSScoring.scoreSegments`), and row `tlBasis` lists the distinct per-leg bases (`"segments: swim pace vs CSS … + normalized power vs FTP + …"`). Row `durationMinutes` stays the parent aggregate — it includes the transitions.
- **Never group by `record.sport`** — go through `sportContributions` / `detailDicts` (see `docs/analytics.md`). A multisport row's own sport is `.other`; only its legs know the disciplines.
- **Each leg carries its own stream** (`streams`, the lzfse `WorkoutStreams` blob base64'd into the segment JSON) and the parent row's `streamsData` stays empty. Slicing one parent-wide stream is not equivalent: it holds a *single* cadence series in whichever discipline's units the watch recorded (steps/min), so a bike leg cut out of it charts running cadence at twice the rpm. The source already fetches each leg's details to score it — the per-leg stream costs no extra request.
- `powerCurveJSON` is built from the **bike** leg only — run power under the cycling key would be a different number masquerading as the real one.

**`date`/`startMinute` are the effective slot** every reader consumes — the planned day while open, the *actual* start once completed (a plan done a day early/late shows and load-counts on the real day). The planned slot survives in `plannedDate`/`plannedStartMinute` (restored by `unlinkActual`, never clobbered by calendar re-sync).

**`overridesJSON` is the sparse athlete-edit layer** (`manual_name`, `manual_distance_m`, `feel`/`rpe`/`notes`) — the durable authority for manual corrections, re-materialized onto the completed section after every source write (`applyOverrides`), so a resync/refetch may rewrite `detailsJSON` blindly.

`migrateWorkoutLayersIfNeeded` (launch, one-time per device) translates pre-layer rows: recovers each completed row's real date/time from `detailsJSON` and lifts `manual_*` keys into the override layer. Completed fields are non-optional (defaulted) so analytics — which reads only completed rows via `store.activities()` — is unaffected.

## `PerformanceMetricRecord`

Holds both **performance** markers (FTP, VO2max, thresholds, zones, weight; speeds raw in m/s) and **wellness** signals (sleep, resting HR, HRV) — both from a *single* athlete-chosen provider (`metrics_source`), so nothing is double-sourced when both reads are on.

## CloudKit mirroring

Every model mirrors into the private CloudKit database (`ModelConfiguration(cloudKitDatabase: .private("iCloud.net.Narica.TriGenius"))`), so the store follows the athlete across devices — syncing when signed into iCloud, degrading to a plain local store when not. Constraints:

- **No `@Attribute(.unique)`** (CloudKit can't enforce it) and every attribute defaulted.
- `TrainingDataStore.deduplicate()` is the merge-time safety net, fired by `observeRemoteChanges()` once per `.NSPersistentStoreRemoteChange` burst, debounced 1.5 s to quiescence since the notification also fires for this process's own writes. It saves only when it removed a duplicate, but the burst **always** posts `trainingDataDidChange` — an import can update rows without leaving a duplicate, and a long-running app must recompute from the merged store.
- `dedupeWorkouts` collapses by **identity**, not just row id: a local plan merges with the `garmin:` mirror row another device created before the CloudKit merge delivered it (matched via `externalRefs["garmin"]`), and a folded plan absorbs a standalone row carrying the same completed activity — the cross-device races that otherwise double-count TL.
- Requires a **paid** Apple Developer membership on the provisioning profile (CloudKit container + `aps-environment` + the `remote-notification` background mode; a personal team can't grant the iCloud capability).

## `UserDefaults` — device-local

App settings (backend/model, `read_sources` CSV, `metrics_source`, `write_target`, last-sync timestamps) **and the ignored-workout blacklist** (`ignored_workouts`, `IgnoredWorkouts`): ids the athlete hid (e.g. a duplicate from a second device), which `ingest` skips up-front. Kept here so it survives a DB clear; managed from Settings → Ignored workouts (restore = un-blacklist + `resync`). Cross-device the blacklist rides **iCloud KVS** (`NSUbiquitousKeyValueStore`): UserDefaults stays the offline-authoritative local mirror, each write also lands in KVS, and `IgnoredWorkouts.startSync()` pulls the cloud value back on launch and on every external change (whole-list last-writer-wins).

## Keychain

The OpenRouter API key and the Garmin login (OAuth tokens + email), all in `KeychainStore` marked synchronizable, so the secrets ride iCloud Keychain to the athlete's other devices (not the CloudKit data store) and never sit in plaintext UserDefaults. `GarminAuth` reads/writes its tokens here; `AppSettings.garminEmail` too. Both one-time-migrate any pre-iCloud UserDefaults value.

## `TrainingDatabase.swift`

The SwiftData store. `@Model` records `WorkoutRecord` and `PerformanceMetricRecord` (+ the ATP and coach-memory models); value-type DTOs (`Ingested*`, `MetricPoint`, `DailyTL`, `PerformanceSnapshot`) cross the actor boundary. The single `ModelContainer` is built from `TrainingDataStore.schema`. A *Coach-memory store API* extension maps the coach-memory rows ↔ the `CoachMemory` value structs. `store.activities()` returns the completed subset; `scheduledWorkouts`/`openScheduledWorkouts` the planned rows. Any mutation posts the coalesced `trainingDataDidChange`.

### Planned↔completed pairing: at ingest, by explicit link only

A completed activity is folded into the open plan whose completion link (`externalRefs["completed"]`) names it — **no date/sport matching** — so a finished plan becomes one row carrying both target and actual, never double-counted in the PMC; the fold adopts the activity's actual date/start.

`CompletedSection` + `applyCompleted` are the single writer of a row's completed section (DTO ingest, `fold(activity:into:)`, dedupe `merge` all go through it), followed by `applyOverrides`. `ingest` builds the link→plan maps once per batch (refs are JSON, not `#Predicate`-able) so an already-folded plan refreshes in place instead of re-creating a standalone; `foldStandaloneCompleted` covers the activity-before-calendar order.

The link comes from the provider: `syncScheduledWorkouts` extracts each own-pushed calendar item's `associatedActivityId` and `applyProviderCompletions` (re-)links the plan, undoing a contradicting pairing. Where no provider link exists (Apple Watch plans have no HealthKit→plan link) the athlete pairs by hand from the detail view via `linkActual`/`unlinkActual` (candidates: all open plans, nearest day first — deliberately unfiltered). `replaceScheduled` only deletes *open* plans.

Schema changes stay **additive** (CloudKit); beyond `migrateWorkoutLayersIfNeeded` there is no migration — a schema reset re-syncs (planned-workout loss acceptable).

### TL scoring and time-in-zone live here, not in the sources

`ingest(_:)` is the single place a completed activity's TL + effective distance are computed (`TLScoring.score` → `TLCalculator`), scored against `PerformanceHistory.snapshot(asOf: activity.date)` — the thresholds current on its own date. **Load-bearing ordering:** the performance-metric series must be present before activities are scored.

`snapshot(asOf:)` is also where a missing `cycling_ftp` may be filled from `vo2max_cycling × weight_kg` (`FTPEstimate`), for watches that never measure one. It is opt-in (`estimate_ftp_from_vo2max`, read from `UserDefaults` when the resolver is built), a measured value always outranks it, and it is derived on read rather than written — an estimate must never sit in the series under the measured key. Both inputs resolve `asOf:` like every other threshold, so a January ride is scored against January's VO2max. Toggling it moves thresholds retroactively, so the Settings row calls `rescoreAllActivities()` — an in-place re-score of every completed row against the stored details, which reaches the same result as a resync without re-fetching a single stream.

**Time-in-zone is derived on the same pass, for the same reason.** A source hands over `IngestedActivity.zoneSamples` — the full-resolution HR / power / grade-adjusted-speed streams, plus `legZoneSamples` keyed by each multisport leg's `sourceId` — and `TLScoring.score` buckets them via `ZoneBucketing` before the TL step, since the HR-zone TL fallback reads what the bucketing just wrote. No source computes its own zones and none passes through a provider's: Garmin's server-side `hrTimeInZone_*`/`powerTimeInZone_*` are deliberately **not** ingested, because their zone model is the athlete's Garmin Connect configuration rather than ours, so two sources would disagree on the same workout.

Alongside the `{z1…z5: seconds}` dicts, `ZoneBucketing` records the z1–z4 **bounds** it used (`hr_zones_bounds`, `cycling.power_zones_bounds`, `running.pace_zones_bounds`). Stored rather than re-derived at display time: a threshold reading ingested later but dated earlier would shift a re-derivation while the seconds and TL stay as scored, so the UI would state a zone the workout was never bucketed against.

`zoneSamples` is transient — bucketed, then dropped; only the `{z1…z5: seconds}` dicts are stored. So the recompute paths (`rescore`, a distance override) can re-score TL but cannot re-bucket: the stored zones stand until the next per-source **re-sync**, exactly like a TL tuning change.

## `DataSyncCoordinator.swift`

`@MainActor` singleton; **the only writer of activity/metric data**.

- `syncAll(_:)` syncs every enabled source, each with its own watermark; `metrics_source` goes first so its thresholds exist before the other source's activities score.
- `sync(source:)` handles one — Garmin: metrics *only when Garmin is metrics_source* + activities + `syncScheduledWorkouts`; Apple Health: workouts always, metrics only when it's the metrics source.
- `reconcileWriteTarget(_:)` re-pushes any open future **locally-authored** plan the target hasn't seen (`store.plansMissingRef`, `source == "local"` only — provider-mirrored plans are display-only). Runs after **every** sync so local-plan changes propagate, and is where the target is **pruned**: `syncTarget.prune(keeping:)` with `store.liveExternalRefIds(target:)` drops any workout the target still holds for a vanished plan. `prune` defaults to no-op (Garmin opts out — provider-authoritative); `AppleWatchWorkoutTarget` removes scheduler plans not in the live set. Local plans are authoritative — a provider-side delete is undone, not mirrored (`syncScheduledWorkouts` clears the dead ref via `store.clearStaleWriteRefs`, reconcile re-pushes).
- `resync(source:)` forgets the watermark and re-pulls from scratch, recomputing each activity in place — the only way already-synced rows pick up newly-extracted fields. Backs the per-source Settings button.

**Plan CRUD lives here** — `addPlan`/`updatePlan`/`movePlan` (`WorkoutNormalizer` → local store → push to the active target, returning a `PlanWriteOutcome`) and `deletePlan(id:)` (removes a plan locally and from every target it reached). `addPlan`/`updatePlan` return `PlanWriteResult`: `WorkoutNormalizer`'s generous plausibility check on targets/duration/distance runs **before any store write**, rejecting clearly-broken input (e.g. a mis-keyed pace) as `.rejected([String])` instead of silently storing it — surfaced as a tool error to the coach and an alert in the workout editor.

This is the single write path for planned workouts, shared by the coach's scheduling tools, the calendar's workout editor (`Features/WorkoutEditor/` — "+" in the calendar nav bar creates, Edit/Delete on `PlannedWorkoutDetailView` edits; `WorkoutDraft` form state round-trips the compact `workout_data` schema), and drag-to-reschedule. Also serves the coach's `get_workouts` from the merged store. Last-sync timestamps in `UserDefaults`.
