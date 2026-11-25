# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

TriGenius is a SwiftUI multiplatform app (iOS / iPadOS / macOS) — an evidence-based AI triathlon coach. JSON keys and tool schemas use **snake_case** throughout.

UI strings, code comments, the system prompt, and tool descriptions are **English**; coach replies go back to the user in their own language (the system prompt instructs the model to "respond in the athlete's language").

TriGenius is intended to be an **open source project**. The model backing all AI features is assumed to be around **70B parameters** — when writing or extending the system prompt, tool descriptions, and the knowledge base (`TriGenius/Assets/Knowledge/`), favor explicit, unambiguous instructions and concrete structure over reasoning that depends on a much larger frontier model.

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

**Tests are scoped to the algorithmic core, not the UI.** `TriGeniusTests/` mirrors `TriGenius/Analytics/` 1:1 (`Analytics/TLCalculatorTests.swift` pins `Analytics/TLCalculator.swift`), golden-master style: one `#expect` per case, expected values hand-computed from the formula. When you change a tested function in `Analytics/` (or the ingest pairing/TL scoring), **update the pinned values in the mirrored test file in the same change** — the pins are the spec. No UI/network/LLM tests. The suite is hosted by the app, so launch sync is guarded off under `XCTestConfigurationFilePath`.

**Don't render previews to check UI work** (no temporary `#Preview`s, no preview snapshots) unless explicitly asked — the user reviews the UI themselves afterwards, and renders cost tokens. Verify UI changes by building.

## Non-negotiables

The athlete trusts the numbers. These override convenience, every time:

- **Accuracy — compute exactly the value the variable is meant to hold.** Never write a plausible stand-in under a different key (the canonical trap: a stream-derived metric like normalized pace/power is unavailable, so the *average* gets written under the normalized key — a different number masquerading as the real one, which then corrupts TL → CL/AL/FR invisibly). If a *measured* value doesn't exist, the field stays **empty/nil**. A substitute is only acceptable when it is a *genuinely different real computation from real data* (e.g. speed from the distance stream, or HR-zone TL when power/pace is absent) **and** its provenance is surfaced in the UI (a `Basis`/source label). Planned/target values are explicit estimates and fine when labelled (`isEstimatedTL`, `~`) — this rule is about *actuals*.
- **Algorithms are source-independent.** A derived metric (normalized pace/speed/power, TL, time-in-zone, …) is computed by exactly *one* shared function in `Analytics/`, fed raw samples by each source. A source may only *shape* its raw data into the common input (parse a stream, expand to ~1 Hz) — never carry its own copy of the computation. Two sources must yield the same number for the same workout. (`NormalizedStream.normalized` is the single normalization core, `GradeAdjustedPace` the single run grade model; the Garmin/HealthKit extractors only produce `(speed, grade, seconds)` and defer to them.)
- **Fallbacks need explicit user approval.** They hide errors and cause surprising behavior. This includes keeping an old algorithm alongside a new one — don't add the fallback path on your own; ask first.
- **No legacy, no dead code, no dead comments.** Comments describe only current gotchas/specifics — never former functionality ("this used to…", "previously this duplicated…"). Don't narrate placement or restate the line below. **A fixed bug is not a gotcha:** if the failure mode is uncritical and unlikely to be reintroduced, explaining it is noise — the code already encodes the answer. Negative example, deleted from `ATPSeasonChart`:
  ```swift
  // Opaque like every other chart tooltip (see `ChartTooltip`): a
  // translucent backdrop over the plot smears stale pixels while the
  // enclosing scroll view moves.
  .background(Color.appSecondaryBackground, in: .rect(…))
  ```
  A comment earns its place only when it stops a *plausible* future edit (there: "never glass/material here" on the shared `ChartTooltip`, once, not at every call site).
- **Every line saved is a good line.** Favour the smaller, well-factored solution; no boilerplate, no unrequested scope.
- **Ask on every change: how does this impact performance, and how does this impact the total line count?** Weigh both before writing — prefer the change that keeps the app fast and the codebase smaller.

When data is missing or a change would touch the data flow / architecture, **check with the user first** — discuss whether to generalize rather than handle it as a one-off, before implementing.

## Architecture

> **Keep this current.** When you change the architecture or data flow (add/remove a store, change who reads/writes what, add a layer, move a responsibility), update this index **and** the detail doc named on the component's line, in the **same** change.

Three pluggable axes meet in `CoachBrain`: the **LLM backend** (who answers), the **read sources** (where athlete data comes from — Apple Health and/or Garmin, in *parallel*), and the **write target** (where planned workouts are pushed — Garmin or Apple Watch). All three swap at runtime from Settings without touching coach logic. Read and write are **independent** (read from Garmin, schedule onto Apple Watch).

### Data flow

A local **SwiftData store** sits between the sources and everything that reads athlete history. On launch and later syncs, `DataSyncCoordinator` pulls from *every enabled* read source into that store; the coach, analytics, and UI all read from it. Planned workouts are owned locally and pushed to the active write target.

```
Apple Health + Garmin ──syncAll──▶ SwiftData store (TrainingDatabase, default.store)
   (parallel read, deduped)            │  WorkoutRecord = planned + completed (one row)
            ┌──────────────────────────┼───────────────────────────┐
            ▼                          ▼                            ▼
   coach get_workouts /        Analytics (TL, PMC,         Dashboard / Calendar /
   get_metric_history          weekly targets, insights)    Performance UI
   (via DataSyncCoord.)               │
            ▲                          ▼
            │                 ProactiveCoach → system-prompt section
   coach add/modify/move/delete ──▶ local plan ──▶ WorkoutSyncTarget (Garmin / Apple Watch)
```

Three persistence layers, by purpose (details: **`docs/store.md`**):
- **SwiftData** (`default.store`) — historical time-series, the ATP, the coach-memory rows, the workout library (`WorkoutTemplate`: dateless normalized `workout_data`), **and the coach's prompt context**. A single **`WorkoutRecord`** is a TrainingPeaks-style unified slot: optional **planned** section (targets + `stepsJSON`) + optional **completed** section (activity + TL + `tlBasis` + `powerCurveJSON` + `streamsData`), with `overridesJSON` as the sparse athlete-edit layer and `date`/`startMinute` as the **effective** slot every reader consumes. A multisport session (triathlon/brick) is **one** row whose legs live in `segmentsJSON`, each a normal single-sport details dict — row TL is their sum, and per-sport aggregation goes through `sportContributions`, never `record.sport`. `PerformanceMetricRecord` holds performance markers *and* wellness signals, both from the single `metrics_source`. Every model **mirrors into the private CloudKit database** — hence no `@Attribute(.unique)`, all attributes defaulted, and `deduplicate()` as the merge-time safety net.
- **`UserDefaults`** — device-local app settings (backend/model, `read_sources`, `metrics_source`, `write_target`, watermarks), the **threshold-calculation opt-ins**, the **dashboard layout** (both `AthleteSettingsSync`) **and the ignored-workout blacklist** (`IgnoredWorkouts`) — the last three mirrored cross-device via iCloud KVS, all kept here so they survive a DB clear.
- **Keychain** — OpenRouter API key + Garmin login (OAuth tokens + email) in `KeychainStore`, marked synchronizable so they ride iCloud Keychain, never plaintext UserDefaults.

Bugs and planned features live in **Linear** (see **Tickets**).

### Components

Each line is the resident summary; the linked doc carries the full contract, gotchas, and rationale — **read it before changing that area.**

**Coach → `docs/coach.md`**
- **`CoachBrain`** (`Coach/CoachBrain.swift`) — `@MainActor @Observable` orchestrator; owns `SYSTEM_PROMPT_TEMPLATE`, history, tool registry, active backend; freezes the prompt per session (cache-stable; time arrives as a user-message stamp). Two execution paths forked on the backend's `managesOwnConversation` (manual `runLoop()` vs. self-managing).
- **LLM backends** (`LLM/`) — the `LLMBackend` protocol; `OpenAICompatibleBackend` (OpenRouter + LM Studio as configs) and `AppleFoundationModelBackend` (on-device). `AppSettings.makeBackend()` builds them.
- **Tools** (`Coach/CoachTools.swift`, `Coach/ATPTools.swift`, `Coach/WebSearchTool.swift`) — JSON-Schema dicts, one definition serving both backends. Always on: `ActivityReadToolHandler` (source-agnostic reads: `get_power_curve`, `get_metric_history`, `set_performance_metric`), `WorkoutSchedulingToolHandler` (`get_workouts` is the *single* unified read for completed + planned; writes delegate to `DataSyncCoordinator` plan CRUD and emit `ChatCard`s), `ProfileToolHandler`, `ATPToolHandler` (the **single** source of truth for season planning). Conditional: `GarminToolHandler`, `WebSearchToolHandler`.
- **`CoachMemory`** (`Coach/CoachMemory.swift`) — `@MainActor` façade over the SwiftData coach-memory rows; sole writer. Two authority tiers: HARD LIMITS (limitations + injuries) vs PREFERENCES (one free-text list). `contextSummary(history:)` feeds the prompt; "MISSING INFORMATION" drives onboarding.
- **Reply ratings** (`Coach/ReplyRatingStore.swift`, `Coach/FeedbackExport.swift`) — a 👍/👎 on a coach reply stores `CoachBrain.ratingContext` (conversation, tool traffic, frozen prompt, backend) as one device-local JSON file; `FeedbackExport` bundles them with the workout ratings into the file Settings shares.
- **Pain reports** (`DataManagement/Local/PainReportStore.swift`) — the athlete's pain check-ins (`PainCheckView`, from the Tissue Load screen) as one device-local JSON file; feedback only — no forecast, prompt or HARD LIMIT reads them.
- **`ProactiveCoach`** (`Coach/ProactiveCoach.swift`) — evaluates PMC/form into proactive signals, split from the chat loop so one evaluation feeds several sinks.

**Data sources & write targets → `docs/data-sources.md`**
- **HealthKit** (`DataManagement/HealthKit/`) — read-only; per-workout records mirror the Garmin schema, run pace grade-adjusted, Garmin-authored workouts dropped to avoid double-counting.
- **Garmin** (`DataManagement/Garmin/`) — layered `GarminAuth` / `GarminClient` / `GarminService` / `GarminTransformations` / builders. Reads and writes. Client + service are `nonisolated final class: Sendable`, deliberately **not** actors.
- **Write targets** (`DataManagement/Workouts/`) — the `WorkoutSyncTarget` protocol; `GarminWorkoutTarget`, `AppleWatchWorkoutTarget` (iOS/WorkoutKit), `UnavailableWorkoutTarget` (macOS); `WorkoutTargetFactory.make(_:)` picks the active one.
- **`CalendarService`** (`DataManagement/Calendar/`) — read-only EventKit wrapper so the coach can plan around busy days.
- **`ref/`** — reference material, **never in the build**: vendored Python Garmin client, captured API payloads, 6 months of real test data, the `tss_lab` validation sandbox, TrainingPeaks screenshots, research notes.

**Local store & sync → `docs/store.md`**
- **`TrainingDatabase.swift`** (`DataManagement/Local/`) — the SwiftData store + DTOs. Planned↔completed pairing happens **at ingest, by explicit link only** (never date/sport matching), and **TL scoring plus time-in-zone bucketing live here, not in the sources** (`ingest` → `TLScoring.score` → `ZoneBucketing`, against the thresholds current on the activity's own date). A source hands over raw `zoneSamples`; it never buckets them, and a provider's own zone dicts are never ingested.
- **Race slots** — each ATP event owns one derived planned row (`race:<id>`, written only by `TrainingDataStore.syncRaceSlots`), its load resolved from the event via `RaceLoad` at read time; never pushed, refused by plan CRUD, paired with the race activity by the manual link.
- **`RouteCache`** (`DataManagement/Local/RouteCache.swift`) — the heatmap's `RouteLine`s, one device-local JSON file per workout in Caches, built from `streamsData` on demand; `applyCompleted` invalidates a workout's file, "Delete all my data" clears them.
- **`DataSyncCoordinator.swift`** — `@MainActor` singleton, the **only** writer of activity/metric data and the single write path for planned workouts (`addPlan`/`updatePlan`/`movePlan`/`deletePlan`, shared by coach tools, the calendar editor, and Siri). `reconcileWriteTarget(_:)` runs after every sync and prunes the target. Garmin syncs fetch only what's missing — a row stored below `GarminService.ingestVersion` counts as missing, so bumping it re-fetches history automatically; `resyncAppleHealth()` re-reads Apple Health.

**Analytics & charts → `docs/analytics.md`**
- **`Analytics/`** — pure, store-fed, no networking: `PMCEngine`, `TL*`, `ZoneModel` (the single `ZoneMetric` definition — bounds, bucketing, details path), `PowerCurve`, `ZoneHistogram` (the stored value→seconds distribution that makes re-bucketing exact), `TrainingLoadAnalytics`, `StreamPlot` (the stream-chart geometry: bucketing, axis model, zone assignment), `MetricAxis` (the metric detail chart's y ticks — never finer than the labels show), `StrengthSets` (the one set model behind the strength table: plan structure, recorded sets, their pairing), `StrengthSession` (the live strength workout's state), `ExercisePose` (an exercise's animation as keyframes from `exercise-poses.json`, elbows and knees by two-bone IK), the ATP engine, `WeeklyTarget`, `PlannedTL`, `RaceLoad` (a planned race's expected TL per leg), `RouteFraming` (the route map's camera, measured off MapKit's projection), `RouteLine` (a GPS track thinned to a drawable line — the heatmap's unit), `DashboardInsight`, and `Analytics/Estimates/` (`VO2maxEstimate` — the VO₂max filter, fed one observation per ride and, through `LTPaceEstimate`, per run — and `CriticalPowerEstimate` — CP/W′ from its prior plus every ride's W′ floors, FTP from CP, the W′ balance — then `LTHREstimate`/`LTPaceEstimate`; each reporting an `EstimateConfidence`). `PlannedWorkoutStructure.swift` is the `@MainActor` display bridge whose `resolvedTargetTL`/`plannedDurationMinutes`/`plannedDistance` every reader goes through. **`Analytics/Tissue/`** is the *second* load axis — the structural one: every session (strength included) maps onto tissue groups, each carrying a forecast of when it is clear for hard work (`TissueLoadModel`, `TissueLogic`, `TissueLeadLine`, `CoachTissueContext`; every model constant in `TissueConstants`); `StrengthProfile` is the athlete's equipment + areas to work around — the coach's filter over `ExerciseLibrary`, the pickers' sort order. `TissueLoadModel` computes the forecasts on the fly from the store (`TissueCardModel.Input.live`): dose per session (TL × sport weights, strength in hard sets with groups from Garmin's catalog via `GarminMuscles`), exponential decay, levels relative to the athlete's own 28-day average, and conflicts as load spikes over the 30-day peak.
- **`Shared/Charts/`** — reusable charts over plain `Codable` value models with **no store access**, plus `SummaryTile` (the one summary card: dashboard, Statistics, chat), `StatStrip` (the figures row under a detail chart), the shared `chartDateScrubbing(_:snap:)` modifier and the Tissue Load primitives (`TissueMarks` — muscle bar, tendon diamond, unlogged hatch; `TissueGrid`; `TissueBodyMap` over `Assets/BodyMap/body-map-geometry.json`; `MuscleMap`, the strength card's primary/secondary figure from `TissueSession.targets`), `ExerciseAnimation` (an exercise's rep drawn from its `ExercisePose`, on the live set page and in the picker), `RouteMap` (the GPS track from `streamsData` behind the workout page's title, Apple Fitness style) and `RouteHeatMap` (every `RouteLine` of a range as stacking translucent strokes). `Features/Statistics/` is the single analysis screen; each of its cards is a `StatCard`, which the dashboard's Pinned section shows the athlete's pick of.

**App, Settings & Siri → `docs/app.md`**
- `App/TriGeniusApp.swift` — builds `CoachBrain` once; `applyBackend` re-applies backend + sources + reconcile on any settings change. Tab UI in `RootTabView`, which carries `measuringWindow()` — the scene root is the only place the window's size is knowable, and `\.windowSize` is how a sheet reads it (`Shared/DesignSystem/WindowSize.swift`).
- `Features/Activities/` — the Activities tab: every completed workout in training weeks, searchable and filterable by sport or to multisport sessions, read-only over lightweight `ActivityListItem`s (`ActivityList` in `Analytics/`).
- `Features/WorkoutEditor/` — the plan/template editor (`WorkoutEditorSheet`; strength exercises edited in place as `ExerciseEditorRow`s, circuits as sections), the single `ExercisePickerView` every exercise choice goes through, the recorded-sets corrector, and the workout library (`TemplateLibraryView`, the calendar's inspector).
- `Features/LiveStrength/` — the live strength workout: a planned strength session done set by set in the app over the pure `StrengthSession`, saved by `DataSyncCoordinator.saveLiveStrength` as an `app:` activity folded into its plan; on iOS mirrored into a Live Activity (`WidgetShared/LiveStrengthAttributes`, drawn by the widget extension).
- `App/SparkleUpdater.swift` (macOS only) — Sparkle auto-update for the Developer-ID build; the one SPM dependency that lives in `project.pbxproj`.
- `Features/Settings/SettingsView.swift` — `AppSettings` + `DataSource`/`WriteTarget` enums; the hub root and its sub-pages (`ConnectionsView`, `PerformanceSettingsView`, `WeeklyTargetsView`, `AIModelSettingsView`, `NotificationSettingsView`); Privacy & Data (incl. "Export my data" and "Delete all my data"); cloud-AI consent gate.
- `AppIntents/` — Siri get/schedule/move/delete over the same plan CRUD, so a Siri write gets the identical validation and target push as a coach write.

## Design

UI work follows **`docs/design.md`** (the normative design system) — modern, compact, data-dense, "Silent AI", Apple's real Liquid Glass (`glassEffect`, not hand-rolled materials). Use the code-backed tokens/surfaces in `TriGenius/Shared/DesignSystem/`: `Theme.Spacing`/`Theme.Radius`/`Theme.Palette` and `.cardSurface()`/`.glassSurface(tint:)`/`.coachAccent(_:)` over magic numbers or raw materials. Content goes on the opaque `.cardSurface()`/`.contentCard()` layer; glass is reserved for the floating control/nav layer. Summaries are `SummaryTile`s; anything that leads somewhere carries a `Chevron`. (Accessibility intentionally deferred.)

## Conventions when extending

The goal is *TrainingPeaks for individual athletes with an AI coach* — this app is meant to grow, so favour maintainable, well-factored solutions over quick fixes. (The **Non-negotiables** above govern correctness, fallbacks, and dead code.)

- **Adding a tool**: define it as a JSON-Schema dict in a `CoachToolHandler` — it works for *both* backends automatically. Parameter names snake_case.
- **Adding a read source**: add a `DataSource` case, ingest it from `DataSyncCoordinator.sync(source:)` (activities always; performance + wellness only when it's the `metrics_source`, ingested *before* /activities so TL scores against present thresholds), rely on the deterministic source-filter dedup. The source-agnostic read tools surface it automatically — no new tool.
- **Adding a write target**: add a `WriteTarget` case, implement `WorkoutSyncTarget`, wire it into `WorkoutTargetFactory`. The single scheduling API and local-first plan flow stay unchanged.
- **Backend differences** belong behind the `LLMBackend` protocol, not in `CoachBrain` — keep the orchestrator source/backend-agnostic.

## Tickets (Linear)

Every bug and planned feature is a Linear issue (team `MAX`, project **TriGenius**), never a list or plan file in the repo. A multi-phase feature is a parent issue: its sub-issues are the steps, its acceptance criteria sit in the parent, and rules the code must keep go into the area's `docs/` file.

- **Triage is the inbox** for raw tickets, often German and rough. Some belong to **Splity**, a separate project: set its project and leave it in Triage untouched.
- **Refining** a TriGenius ticket: set the project, translate to English, label `Bug` / `Feature` / `Improvement`, title the defect or the outcome. Body: Bug → Steps / Actual / Expected; otherwise target behaviour, then the current state. Whatever the author left open becomes an **Open decision:** line. Stay faithful — no added scope, no guessed solution, no priority; name code only after checking it in the repo. Then accept it into Backlog.
- **Status:** the user moves tickets to Todo. Starting one → In Progress; it builds and the tests pass → In Review (the user reviews the UI). Only the user sets Done.
