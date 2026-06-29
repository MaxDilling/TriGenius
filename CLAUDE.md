# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

TriGenius is a SwiftUI multiplatform app (iOS / iPadOS / macOS) — an evidence-based AI triathlon coach. JSON keys and tool schemas use **snake_case** throughout.

UI strings, code comments, the system prompt, and tool descriptions are **English**; coach replies go back to the user in their own language (the system prompt instructs the model to "respond in the athlete's language").

## Build & run

- Single Xcode project, two schemes share the `TriGenius` app target; a `TriGeniusTests` unit-test target (Swift Testing) covers the pure `Analytics/` + ingest core. Requires **Xcode-beta** (deployment targets iOS 27+/macOS 27+; the Apple Intelligence backend needs the iOS/macOS 27 FoundationModels framework). Prefer building/running through the IDE.
- Xcode **synchronized groups** (`PBXFileSystemSynchronizedRootGroup`, `objectVersion = 90`): the `TriGenius/` and `TriGeniusTests/` trees map directly to their targets — new `.swift` files anywhere under them are picked up automatically; **do not** edit `project.pbxproj`.

```bash
# Simulator
xcodebuild -project TriGenius.xcodeproj -scheme TriGenius \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
# macOS
xcodebuild -project TriGenius.xcodeproj -scheme TriGenius \
  -destination 'platform=macOS' build
# Tests — run on macOS (pure logic, no simulator boot; the iOS-sim host install
# trips over the embedded widget's plugin data container).
xcodebuild test -project TriGenius.xcodeproj -scheme TriGenius \
  -destination 'platform=macOS' -only-testing:TriGeniusTests -allowProvisioningUpdates
```

**Tests are scoped to the algorithmic core, not the UI.** `TriGeniusTests/` mirrors `TriGenius/Analytics/` 1:1 (`Analytics/TSSCalculatorTests.swift` pins `Analytics/TSSCalculator.swift`), golden-master style: one `#expect` per case, expected values hand-computed from the formula. When you change a tested function in `Analytics/` (or the ingest pairing/TSS scoring), **update the pinned values in the mirrored test file in the same change** — the pins are the spec. No UI/network/LLM tests. The suite is hosted by the app, so launch sync is guarded off under `XCTestConfigurationFilePath`.

## Non-negotiables

The athlete trusts the numbers. These override convenience, every time:

- **Accuracy — compute exactly the value the variable is meant to hold.** Never write a plausible stand-in under a different key (the canonical trap: a stream-derived metric like normalized pace/power is unavailable, so the *average* gets written under the normalized key — a different number masquerading as the real one, which then corrupts TSS → CTL/ATL/TSB invisibly). If a *measured* value doesn't exist, the field stays **empty/nil**. A substitute is only acceptable when it is a *genuinely different real computation from real data* (e.g. speed from the distance stream, or HR-zone TSS when power/pace is absent) **and** its provenance is surfaced in the UI (a `Basis`/source label). Planned/target values are explicit estimates and fine when labelled (`isEstimatedTSS`, `~`) — this rule is about *actuals*.
- **Algorithms are source-independent.** A derived metric (normalized pace/speed/power, TSS, time-in-zone, …) is computed by exactly *one* shared function in `Analytics/`, fed raw samples by each source. A source may only *shape* its raw data into the common input (parse a stream, expand to ~1 Hz) — never carry its own copy of the computation. Two sources must yield the same number for the same workout. (E.g. `NormalizedStream.normalized` is the single normalization core, `GradeAdjustedPace` the single run grade model; the Garmin/HealthKit extractors only produce `(speed, grade, seconds)` and defer to them.)
- **Fallbacks need explicit user approval.** They hide errors and cause surprising behavior. This includes keeping an old algorithm alongside a new one — don't add the fallback path on your own; ask first.
- **No legacy, no dead code, no dead comments.** Comments describe only current gotchas/specifics — never former functionality ("this used to…", "previously this duplicated…"). Don't narrate placement or restate the line below.
- **Every line saved is a good line.** Favour the smaller, well-factored solution; no boilerplate, no unrequested scope.

When data is missing or a change would touch the data flow / architecture, **check with the user first** — discuss whether to generalize rather than handle it as a one-off, before implementing.

## Architecture

> **Keep this current.** When you change the architecture or data flow (add/remove a store, change who reads/writes what, add a layer, move a responsibility), update the relevant section here in the **same** change.

Three pluggable axes meet in `CoachBrain`: the **LLM backend** (who answers), the **read sources** (where athlete data comes from — Apple Health and/or Garmin, in *parallel*), and the **write target** (where planned workouts are pushed — Garmin or Apple Watch). All three swap at runtime from Settings without touching coach logic. Read and write are **independent** (read from Garmin, schedule onto Apple Watch).

### Data flow

A local **SwiftData store** sits between the sources and everything that reads athlete history. On launch and later syncs, `DataSyncCoordinator` pulls from *every enabled* read source into that store; the coach, analytics, and UI all read from it. Planned workouts are owned locally and pushed to the active write target.

```
Apple Health + Garmin ──syncAll──▶ SwiftData store (TrainingDatabase, default.store)
   (parallel read, deduped)            │  WorkoutRecord = planned + completed (one row)
            ┌──────────────────────────┼───────────────────────────┐
            ▼                          ▼                            ▼
   coach get_activities /      Analytics (TSS, PMC,         Dashboard / Calendar /
   get_health_metrics          weekly targets, insights)    Performance UI
   (via DataSyncCoord.)               │
            ▲                          ▼
            │                 ProactiveCoach → system-prompt section
   coach add/modify/move/delete ──▶ local plan ──▶ WorkoutSyncTarget (Garmin / Apple Watch)
```

Three persistence stores, by purpose:
- **SwiftData** (`default.store`) — historical time-series. A single **`WorkoutRecord`** is a TrainingPeaks-style unified slot with an optional **planned** section (targets + structured `stepsJSON`) and an optional **completed** section (finished activity + TSS); `isPlanned`/`isCompleted` flag which are present, `externalRefsJSON` maps each write target → provider id. Completed fields are non-optional (defaulted) so analytics (which reads only completed rows via `store.activities()`) is unaffected. `PerformanceMetricRecord` holds both **performance** markers (FTP, VO2max, thresholds, zones, weight; speeds raw in m/s) and **wellness** signals (sleep, resting HR, HRV) — both from a *single* athlete-chosen provider (`metrics_source`), so nothing is double-sourced when both reads are on.
- **`coach_memory.json`** (Application Support) — the coach's *prompt context*: profile, preferences, weekly structure (incl. the `sport_ratio`/`sport_floors` driving the ATP per-sport split), sport progress, feedback. The season plan itself is **not** here — it's the ATP in SwiftData. Deliberately separate from the time-series store.
- **`UserDefaults`** — app settings (backend/model, `read_sources` CSV, `metrics_source`, `write_target`, API key, Garmin email, last-sync timestamps) **and the ignored-workout blacklist** (`ignored_workouts`, `IgnoredWorkouts`): ids the athlete hid (a duplicate from a second device), which `ingest` skips up-front. Kept here so it survives a DB clear; managed from Settings → Ignored workouts (restore = un-blacklist + `resync`).

Planned features live in **`FEATURES.md`**; bugs in **`BUGS.md`**.

### Components

**CoachBrain** (`Coach/CoachBrain.swift`) — the orchestrator. `@MainActor @Observable`; owns `SYSTEM_PROMPT_TEMPLATE`, conversation history, the tool registry, and the active backend. Builds the system prompt each turn (current date/time, `memory.contextSummary`, a data/devices section enumerating active sources + target). `setSources(read:write:)` rebuilds the tool registry (`configureTools`). Two execution paths, forked on the backend's `managesOwnConversation`:
- **CoachBrain-driven** (Gemini): `runLoop()` drives the tool-call loop manually (stream a turn → execute any tool calls → append results as a synthetic user turn → repeat, max `maxToolIterations = 8`).
- **Self-managing** (Apple FM): backend owns its transcript and runs tools internally; CoachBrain feeds the latest user message and hands it a tool-executor closure.

**LLM backends** (`LLM/`) — the `LLMBackend` protocol (`LLM/LLMService.swift`); `managesOwnConversation` is the key fork, default extensions let stateless backends ignore the self-managing methods. `BackendFactory`/`BackendType` select the impl.
- **GeminiBackend** (`GeminiService.swift`): stateless REST (`gemini-2.5-flash` default). Gotcha: `ToolCallRecord.thoughtSignature` is an opaque token Gemini "thinking" models require echoed back.
- **AppleFoundationModelBackend** (`AppleFoundationModelService.swift`): on-device, `@available(iOS 26)`, self-managing via a persistent `LanguageModelSession`. `CoachToolBridge.swift` converts each tool's JSON-Schema `parameters` into a FoundationModels `GenerationSchema` at runtime, so tools are defined once (JSON-Schema) for both backends.

**Tools** (`Coach/CoachTools.swift`) — `CoachToolHandler` + `CoachToolRegistry`, all `@MainActor`. Tool parameters are dicts literally shaped like JSON Schema — the same dict feeds Gemini's API and `CoachToolBridge`.
- **Reads are source-agnostic**: `ActivityReadToolHandler` (always on) serves `get_activities`/`get_health_metrics` from the merged store via `DataSyncCoordinator`. The wellness series comes from the single `metrics_source`, not both.
- **Writes go through one API → the active target**: `WorkoutSchedulingToolHandler(writeTarget:)` (always on) owns `get_workouts`/`add_workouts`/`modify_workout`/`move_workout`/`delete_workout`. Writes the plan to the local store first (source of truth), then pushes to the active `WorkoutSyncTarget`, recording the external id on the `WorkoutRecord`.
- **`GarminToolHandler`** registered only when Garmin is a read source; carries the genuinely Garmin-specific extras (`get_power_curve`, `sync_user_settings`).
- **`ProfileToolHandler`** always on (profile read/write + `read_knowledge`). The knowledge base is Markdown under `TriGenius/Assets/Knowledge/` (`CYCLING.md`, `RUNNING.md`, `SWIMMING.md`, `INJURIES.MD`, `WORKOUTS.md`), loaded from the bundle via `knowledgeFiles`.
- **`ATPToolHandler`** (`Coach/ATPTools.swift`) always on — the coach's window onto the season plan, composable so each call touches one concern (the engine re-periodizes after any change): `get_atp` (config, events **with ids**, pinned weeks, current period + this week's TSS, next-A projection, upcoming weeks); `set_atp` (merge-update the methodology/volume config only); `set_atp_event` (upsert one race — omit `event_id` to add, pass it to update; merge-update); `delete_atp_event`; `pin_atp_week`/`unpin_atp_week` (write/clear an `ATPWeekOverride` so the coach can lock a week's TSS, `tss 0` = rest). All read/write `TrainingDataStore`'s ATP API; the coach supplies events + params, never weekly numbers. `get_atp` returns JSON; the mutating tools return the same JSON state with a `message` field. Its `promptSection()` injects a compact ATP summary into the system prompt each turn (alongside the PMC section). The ATP is the **single** source of truth for season planning — there is no separate phase model (the old `set_training_plan` tool and `Phase`/`TrainingPlan` are gone).

**Data sources** (`DataManagement/`):
- **HealthKit** (`HealthKit/HealthKitService.swift`): read-only Apple Health — workouts, performance markers (FTP/VO2max/weight), daily wellness (`fetchWellnessMetrics`). Per-workout records mirror the Garmin schema: `normalizedRecord(for:hrZoneBounds:)` streams the same `detailsJSON` keys the detail view and `TSSCalculator` consume. Run normalized pace is grade-adjusted (true NGP): `speedStream` attaches GPS-route gradient to each running sample and defers to `GradeAdjustedPace`/`NormalizedStream`; indoor runs reduce to plain normalized speed. Apple Health has no time-in-zone, so `fetchActivities` derives HR-zone bounds from the athlete's thresholds as of each workout's date (`HRZones.upperBounds`, %LTHR — requires a *measured* LTHR, never estimated from max HR) and buckets the high-res HR stream into `hr_zones_seconds` (the HR-zone TSS fallback's input). The HR stream comes from `HKQuantitySeriesSampleQuery` (≈1 s), not the ≈2.5 min aggregated samples. Dedup is deterministic: `isGarmin(_:)` drops any workout authored by Garmin Connect, so a Garmin session mirrored into Apple Health is never double-counted.
- **Garmin** (`DataManagement/Garmin/`): layered — `GarminAuth` (SSO/MFA → OAuth), `GarminClient` (low-level connectapi), `GarminService` (high-level orchestration, returns ToolResult-style JSON), `GarminTransformations` (pure response-shaping), `GarminWorkoutBuilder`, `GarminMappings`. Reads and writes.
- **Reference material lives in `ref/`** (none of it is in the build — never import or ship it; port behavior into Swift). Useful when extending:
  - `ref/garmin_health_data/` — a vendored Python Garmin Connect client; the worked example for endpoint URLs, response shapes, and the token exchange (start with `garmin_client/api.py`, `constants.py`, `client.py`).
  - `ref/garmin_api/` — captured raw Garmin API responses (e.g. `swimDetails`) for checking exact payload shapes.
  - `ref/testdata/` — 6 months of real Garmin data: `garmin_data.db` (read-only, the lab's input) + exported `garmin_files/`. Plus sample exports `ref/workout_garmin_*.json` / `ref/workout_healthkit_*.json` for comparing the two source schemas.
  - `ref/tss_lab/` — a Python sandbox for designing and **validating** TSS/PMC algorithms against `testdata/` before hand-porting into Swift (`harness.py` → validation report/plots; `pytest` regression gates; `PORTING.md` tracks what's been ported). The TriGenius `Analytics/` formulas should match it.
  - `ref/TrainingPeak Screenshots/` — TrainingPeaks UI/behavior reference (e.g. `ATP/` for the annual training plan, weekly-TSS and CTL flows) for matching established conventions.
  - `ref/knowlage/` — background research notes (cycling/running/swimming) behind the in-app knowledge base.

**Write targets** (`DataManagement/Workouts/`) — the `WorkoutSyncTarget` protocol is the seam for "where planned workouts go": `schedule/update/move/delete` a `PlannedWorkout`, returning a `WorkoutWriteResult` with the provider's external id. `WorkoutTargetFactory.make(_:)` builds the active one.
- **`GarminWorkoutTarget`**: thin adapter over `GarminService` + `GarminWorkoutBuilder`.
- **`AppleWatchWorkoutTarget`** (iOS-only, `#if os(iOS)`): WorkoutKit. `AppleWatchWorkoutBuilder` translates the canonical compact steps into a `CustomWorkout` (swim/bike/run only — others → nil). Gotcha: `CustomWorkout`'s initializer *traps* on anything it rejects, so the builder gates on `CustomWorkout.supportsActivity`/`supportsAlert`, dropping an alert the activity can't carry (e.g. pace on a swim) while keeping goal + interval structure. External ref is the `WorkoutPlan` UUID. macOS uses `UnavailableWorkoutTarget`.
- **`WorkoutPayloadBuilder`** reconstructs `workout_data` from a stored plan, so any plan re-materializes for any target from the local source of truth.
- **Metric history** is pulled via `GarminService.fetchMetricHistory` — one concurrent *range* call per metric type (HRV, sleep + resting HR, weight, VO2max, FTP/CSS/threshold), parsed by `GarminTransform.parse*` into dated `IngestedMetric`s. Gotcha: the sleep-stats endpoint caps each request at **28 days** (`BadRequestException: Exceeded max number of days`), so `fetchSleepStats` splits into ≤28-day chunks, fetches concurrently, merges before parsing — without it a deep backfill silently drops the whole sleep/resting-HR series. Range failures are logged via `os.Logger` (`subsystem: net.Narica.TriGenius, category: Garmin`). `syncUserSettings` covers what ranges don't (HR zones, max HR, power zones from current FTP).

**Local store & sync** (`DataManagement/Local/`):
- **`TrainingDatabase.swift`** — the SwiftData store. `@Model` records `WorkoutRecord` and `PerformanceMetricRecord`; value-type DTOs (`Ingested*`, `MetricPoint`, `DailyTSS`, `PerformanceSnapshot`) cross the actor boundary. `store.activities()` returns the completed subset; `scheduledWorkouts`/`openScheduledWorkouts` the planned rows. Any mutation posts the coalesced `trainingDataDidChange`.
  - **Planned↔completed pairing happens at ingest.** A completed activity is folded into a matching open plan (the plan's Garmin link via `externalRefs`, else same-day + same sport-family + nearest start time) so a finished plan becomes one row carrying both target and actual — never double-counted in the PMC. `foldStandaloneCompleted` covers the reverse order; `ingest` checks `foldedPlan(forActivityId:on:)` *before* the id-match so a re-sync refreshes the folded actuals in place instead of re-creating a standalone. Gotcha: the heuristic can mis-pair when two sources record the same session (Apple Watch plans have no HealthKit→plan link); the athlete fixes it from the detail view via `unlinkActual` then `linkActual` (both route through the shared `fold(activity:into:)`). `replaceScheduled` only deletes *open* plans. No migration — a schema reset re-syncs (planned-workout loss acceptable).
  - **TSS scoring lives here, not in the sources.** `ingest(_:)` is the single place a completed activity's TSS + effective distance are computed (`TSSScoring.score` → `TSSCalculator`), scored against `PerformanceHistory.snapshot(asOf: activity.date)` — the thresholds current on its own date. Load-bearing ordering: the performance-metric series must be present before activities are scored.
- **`DataSyncCoordinator.swift`** (`@MainActor` singleton) — the only writer of activity/metric data. `syncAll(_:)` syncs every enabled source (each with its own watermark; `metrics_source` first so its thresholds exist before the other source's activities score); `sync(source:)` handles one (Garmin: metrics *only when Garmin is metrics_source* + activities + `syncScheduledWorkouts`; Apple Health: workouts always, metrics only when it's the metrics source). `reconcileWriteTarget(_:)` re-pushes any open future **locally-authored** plan the target hasn't seen (`store.plansMissingRef`, `source == "local"` only — provider-mirrored plans are display-only), runs after **every** sync so local-plan changes propagate, and is where the target is **pruned**: `syncTarget.prune(keeping:)` with `store.liveExternalRefIds(target:)` drops any workout the target still holds for a vanished plan. `prune` defaults to no-op (Garmin opts out — provider-authoritative); `AppleWatchWorkoutTarget` removes scheduler plans not in the live set. Local plans are authoritative — a provider-side delete is undone, not mirrored (`syncScheduledWorkouts` clears the dead ref via `store.clearStaleWriteRefs`, reconcile re-pushes). `resync(source:)` forgets the watermark and re-pulls from scratch, recomputing each activity in place (the only way already-synced rows pick up newly-extracted fields); backs the per-source Settings button. `deletePlan(id:)` removes a plan locally and from every target it reached. Serves the coach's `get_activities`/`get_health_metrics`/`get_workouts` from the merged store. Last-sync timestamps in `UserDefaults`.

**Analytics & proactive coaching** (`Analytics/`, `Coach/ProactiveCoach.swift`):
- **`Analytics/`** — a pure, store-fed layer (no networking): `PMCEngine` (CTL/ATL/TSB from daily TSS, TrainingPeaks EWMA), `TSS*` (scoring/calculation/constants), `HRZones` (HR-zone bounds from LTHR/max HR + bucket a HR stream into time-in-zone), `TrainingLoadAnalytics`, the ATP engine (`ATPEngine`/`ATPPeriodization`/`ATPConstants`/`ATPSportSplit` — the season plan; CTL via `PMCEngine`), `WeeklyTarget`, `DashboardInsight`. Mostly `enum`/`struct` `static` functions over `WorkoutRecord` arrays — no shared state. **`WeeklyTarget`** is fed by the ATP: the current ATP week's TSS is split across swim/bike/run by `ATPSportSplit` (the athlete's `sport_ratio`/`sport_floors` from `WeeklyStructure`), back-estimating each discipline's duration/distance; with no ATP yet it falls back to a flat hour-budget heuristic. Scheduled workouts only *raise* the goal.
- **`ProactiveCoach.swift`** — evaluates current state (PMC/form) and emits proactive signals; split from the chat loop so one evaluation feeds two sinks (a system-prompt section now, push notifications later).
- **`CalendarService.swift`** (`DataManagement/Calendar/`) — read-only EventKit wrapper; a cross-cutting always-available source that lets the coach plan around busy days.

**Memory** (`Coach/CoachMemory.swift`) — `ObservableObject` persisting profile, preferences, weekly structure, sport progress, feedback as `coach_memory.json` (Application Support); snake_case keys, each model has `init(from:)`/`toDict()`. No season plan here (that's the ATP in SwiftData); `WeeklyStructure` carries the ATP sport-split `sport_ratio`/`sport_floors`. `contextSummary` is injected into the system prompt; "FEHLENDE INFORMATIONEN" drives the onboarding flow.

**App entry & settings**:
- `App/TriGeniusApp.swift` — builds `CoachBrain` once; `applyBackend` re-applies backend + `setSources` + `reconcileWriteTarget` on any settings change. Launch does `syncAll(readSources)` then `reconcileWriteTarget`. Tab UI in `RootTabView`.
- `Features/Settings/SettingsView.swift` — `AppSettings` (`ObservableObject`) + `DataSource`/`WriteTarget` enums. Persists API key, backend/model, `read_sources` (≥1 always on), `metrics_source` (clamped to an enabled read source), `write_target` (Apple Watch hidden on macOS), Garmin email; `AppSettings.stored*()` expose them to non-SwiftUI callers. UI: a "Read From" section (toggles + a "Metrics from" picker when both are on), one section per enabled source (Garmin login + a `ReadSourceSyncSection` "Re-sync" button → `resync(source:)`), then a "Write To" picker. `makeBackend()` is the single place backends are built.

## Design

UI work follows **`DESIGN.md`** (the normative design system) — modern, compact, data-dense, "Silent AI", Apple's real Liquid Glass (`glassEffect`, not hand-rolled materials). Use the code-backed tokens/surfaces in `TriGenius/Shared/DesignSystem/`: `Theme.Spacing`/`Theme.Radius`/`Theme.Palette` and `.cardSurface()`/`.glassSurface(tint:)`/`.coachAccent(_:)` over magic numbers or raw materials. Content goes on the opaque `.cardSurface()` layer; glass is reserved for the floating control/nav layer. **`DESIGN_CHANGES.md`** is the rollout checklist. (Accessibility intentionally deferred.)

## Conventions when extending

The goal is *TrainingPeaks for individual athletes with an AI coach* — this app is meant to grow, so favour maintainable, well-factored solutions over quick fixes. (The **Non-negotiables** above govern correctness, fallbacks, and dead code.)

- **Adding a tool**: define it as a JSON-Schema dict in a `CoachToolHandler` — it works for *both* backends automatically. Parameter names snake_case.
- **Adding a read source**: add a `DataSource` case, ingest it from `DataSyncCoordinator.sync(source:)` (activities always; performance + wellness only when it's the `metrics_source`, ingested *before* activities so TSS scores against present thresholds), rely on the deterministic source-filter dedup. The source-agnostic read tools surface it automatically — no new tool.
- **Adding a write target**: add a `WriteTarget` case, implement `WorkoutSyncTarget`, wire it into `WorkoutTargetFactory`. The single scheduling API and local-first plan flow stay unchanged.
- **Backend differences** belong behind the `LLMBackend` protocol, not in `CoachBrain` — keep the orchestrator source/backend-agnostic.
