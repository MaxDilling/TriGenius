# PERFORMANCE_TODO.md

Working document for performance improvements. Tracks open TODOs, findings, and
results. We work **one item at a time**, top to bottom by priority.

## The rule: measure first, always

We **never** optimize from reading code alone. For every item we:

1. **Reproduce** the slow path with a concrete, repeatable scenario (which screen,
   which action, what data size — e.g. "cold launch with 6 months of Garmin data").
2. **Profile it** before touching anything — capture a baseline number. Instruments
   templates per case:
   - **Time Profiler** — CPU hotspots, main-thread stalls, where time actually goes.
   - **SwiftUI** instrument — view body re-evaluations, long `body` computations,
     "Update Groups" hangs.
   - **Core Data / SwiftData** instrument — fetch count, fault firing, fetch duration.
   - **Allocations / Leaks** — retain growth, transient churn during scroll/sync.
   - **Network** — Garmin request count / waterfall / latency.
   - **os_signpost** (`PointsOfInterest`) — wrap our own suspected spans so we can
     read them directly in the timeline (see TODO-0).
3. **Record the baseline number here** (ms, allocs, fetch count) under the item.
4. Form a hypothesis, make the change, **re-profile**, record the delta.
5. Only then mark the item done. A change without a before/after measurement is not done.

> Profiling note: build the **Release** configuration for timing (Debug Swift is far
> slower and misleading). Use the same `ref/testdata/` dataset each time so numbers are
> comparable across sessions.
>
> **Reference hardware:** M1 Max, both as the **iPhone 17 Pro Simulator** (primary
> baseline for iOS UI/widget paths) and running **macOS natively** (cleaner for pure
> compute paths — analytics, ingest, sync, serialization). Run both when a result may be
> device-specific (e.g. SwiftUI/Chart rendering); note which one a baseline used.

### Result log format

When closing an item, append a line:

```
[YYYY-MM-DD] <item> — baseline <X> → after <Y> (<−Z%>). Change: <what>. Tool: <instrument>.
```

---

## TODO-0 — Instrument the app (done — prerequisite for everything below)

Signposts live in `TriGenius/Shared/Perf.swift` (`OSSignposter`, subsystem
`net.Narica.TriGenius`, category `.pointsOfInterest`). API: `let s = Perf.begin("name"[,
label]); defer { Perf.end(s) }` — each interval gets a fresh id so concurrent same-name
spans (parallel per-source sync) don't conflate. `Perf` is `nonisolated` so it also wraps
Garmin's non-main-actor network methods; free when not recording.

Spans/events currently in place: `syncAll`; `sync` (per source); `ingest`;
`PMCEngine.current`; `ATPEngine.build`; `DashboardVM.load`; `buildSystemPrompt`; `tool`
(per tool call, both backends); Garmin sub-spans `garmin.metrics` / `garmin.activities` /
`garmin.scheduled` / `garmin.activityDetail` (per new activity) / `garmin.calendarMonth` /
`garmin.schedFetch` / `garmin.wktFetch`, plus **`garmin.api`** wrapping every raw
`connectapi` call (labelled `<METHOD> <path>`); `Calendar.loadData` / `loadCalendar`;
`tabSwitch`; `ATP.load`; and the recompute-storm events `remoteChange` / `deduplicate` /
`trainingDataDidChange`. Verified visible under "Points of Interest" in an Instruments
trace. Add new spans the same way, scoped to whatever's being measured next.

---

## TODO-CAL — Calendar tab (mostly resolved; one low-risk follow-up parked)

- **Path:** `Features/Calendar/` — `CalendarView` → `CalendarViewModel` →
  `WeekTimeGridView` (week time-grid) + `CalendarNavBar`. Observes `trainingDataDidChange`.
- **Data path (Finding 1, B-prio, parked):** `Calendar.loadCalendar` (synchronous EventKit
  over a 20-week window, main thread) is ~90–95% of every `Calendar.loadData` (88 ms
  tab-open baseline). Confirmed not the dominant cost; revisit only if it resurfaces.
- **Dominant cost (Finding 2, FIXED) — week-scroll re-laid out the whole grid every
  frame.** Root cause chain and fixes, in order of leverage:
  1. Baseline (3 s scroll window): **172k SwiftUI body evals / 3.06 s**, dominated by
     `ForEach` (18,374 / 1.50 s) and `_ShapeView` (22,786 / 429 ms). `DayColumnGrid`/
     `DayHeaderCell` fed pre-computed data as `Equatable` value views (`.equatable()`) —
     confirmed body-evals stopped re-running (`EquatableView` → 66 evals), but this
     *wasn't* the dominant cost: SwiftUI's `.equatable()` skips body *evaluation*, not
     layout/render, so total time barely moved.
  2. Real cost was **render/layout volume**: ~175 per-column hour-line `Rectangle`s + 25
     gutter `Text`s recomputed every scroll frame (`_ShapeView` 21,022). Fixed by drawing
     all hour lines in one `Canvas` (`HourGridlines`) instead of per-column shapes —
     `_ShapeView` dropped to 3,426; `ForEach` (layout, not our bodies) stayed the residual
     cost at ~1.35 s.
  3. Residual cost, found via SwiftUI's Update Groups / Change Call Tree: two writes drove
     most of the remaining layout churn. `firstVisibleDay` cascaded into `headerHeight`
     (a leading-day change during scroll repadded *every* column — 16.2% of all changes)
     and the per-frame `offset` write fed `.offset()` on gutter/corner/header (23.8% of
     commits). Fixed `headerHeight` by sizing it from the loaded-window's busiest all-day
     day (`loadedMaxAllDayCount`) instead of the live visible slice — decoupled from
     scroll, no rotation risk. User-confirmed "deutlich flüssiger" after this fix; the
     remaining breakdown was `ScrollViewHelper.updateGraphState` 48% (framework-inherent)
     and the still-live `offset` write 19.8% (rotation-sensitive, deferred — see below).
  4. Month view had the same pattern in `visibleMonth` (day-cell dimming invalidated
     every scroll frame, 15.4% of changes) — fixed with a same-value guard so it only
     fires on an actual month crossing.
- **Open, deferred (low priority):** isolating the per-frame `offset` write itself would
  close the remaining ~20% of week-scroll cost, but touches where offset is read/applied
  and carries rotation/de-sync risk. Not worth it unless a real device shows actual
  hitches — the scroll already measures smooth.

---

## TODO-1 — Cold launch & first sync (mostly resolved; device re-measure pending)

- **Path:** `TriGeniusApp` launch → `DataSyncCoordinator.syncAll` → per-source sync →
  `ingest` (TL scoring) → `reconcileWriteTarget`.
- **Baseline (macOS):** `syncAll` 4.42 s, ~entirely the Garmin sync; compute side
  (`DashboardVM.load`, `PMCEngine.current`, `ATPEngine.build` combined) is noise (<50 ms).
- **Root cause (via `garmin.*` sub-spans, warm launch) — serial N+1 network fetches.**
  `syncScheduledWorkouts` was the dominant cost (**2.38 s of the 4.42 s, 62%**; vs.
  `garmin.activities` 797 ms / `garmin.metrics` 623 ms). Request-level trace
  (`garmin.api`, per-call spans) broke the 2.38 s down further:
  - **2× redundant `/activitylist-service/.../activities` calls (~0.9 s)** — the
    scheduled sync also fetched completed activities via pagination and then discarded
    them (`parseScheduledWorkouts` only reads the `scheduled` key); activities are
    already synced separately.
  - **5× serial `/workout-service/schedule/*` calls (~140–167 ms each)** — one per
    planned workout, the true N+1 loop (no `getWorkoutDetails` fallback calls seen, so
    that hypothesized double-call was refuted).
  - **2× serial `/calendar-service/.../month/*` calls (442 + 539 ms).**
- **Fixes implemented:** dropped the redundant completed-fetch from the scheduled sync
  (`includeCompleted: Bool` param, sync passes `false`); parallelized the calendar-month
  calls, the per-workout schedule-detail fetches, and `syncUserSettings`'s HR-zones/FTP
  calls (`TaskGroup`/`async let`); `fetchMetricHistory` now runs concurrently with
  `syncUserSettings`. Store-write ordering preserved (single `replaceScheduled` write at
  the end; metrics still ingest before activities for TL scoring) — no fold/replace
  race. Expected: `garmin.scheduled` 2.38 s → ~0.7 s, whole sync ~3.8 s → ~1.7 s.
  **Re-measure still pending.**
- **Separately — the UI was blocked on this sync before first paint.** Launch awaited
  `syncAll` → `reconcileWriteTarget` → `ReminderScheduler.reconcile` serially before
  revealing the UI, even though the local SwiftData store already holds usable cached
  data. **Decision (approved): "cached-first, refresh-on-arrival."** Implemented — the UI
  now reveals from the cached store immediately, sync runs in a background `Task`, views
  refresh via the existing `trainingDataDidChange` observation; removed the blocking
  "Synchronisiere…" screen. **Trade-off (accepted):** the first few seconds may show
  last-sync data; self-heals on arrival. **Deferred, not required:** gating only the
  Coach *send* action on an in-flight sync so a mid-sync chat can't answer from stale
  history.
- **Still open:** confirm the Garmin-sync fixes on the iPhone 17 Pro Sim (all traces so
  far are macOS); `garmin.metrics` (~0.6 s) is a smaller secondary target if still
  material after re-measure.

---

## TODO-2 — `trainingDataDidChange` fan-out (recompute storms) — FIXED, re-measured

- **Path:** any store mutation posts `trainingDataDidChange` → observed by
  Dashboard/Calendar/ATP/PerformanceMetrics/PlannedWorkoutDetail.
- **Root cause (confirmed via `remoteChange`/`deduplicate`/`trainingDataDidChange`
  signposts):** SwiftData+CloudKit posts `.NSPersistentStoreRemoteChange` for our *own*
  local writes too, and `deduplicate()` unconditionally saved + posted
  `trainingDataDidChange` even when it deleted nothing — a self-sustaining ~200 ms-period
  storm (remoteChange → deduplicate → didChange → DashboardVM.load → next remoteChange).
- **Baseline (launch window):** `deduplicate` 30× / 1.71 s (all no-ops);
  `DashboardVM.load` 26× / 2.28 s — ~4 s of main-thread work for zero information gain,
  the launch micro-hang generator.
- **Fixes implemented:** `deduplicate()` now only saves/`markChanged()` when
  `context.hasChanges` (a no-op pass stays silent); `observeRemoteChanges()` debounces to
  quiescence (1.5 s trailing) so a notification burst triggers one dedup, not one per
  runloop tick.
- **Re-measured:** `deduplicate` 30×/1.71 s → **1×/70 ms**; `DashboardVM.load` 26×/2.28 s
  → **3×/343 ms**; `trainingDataDidChange` ~26 → **2**. Storm confirmed fixed.
- **Follow-up moved to TODO-3:** `PMCEngine.current` still runs twice per dashboard load
  (~110 ms) — once directly, once nested inside `ATPEngine.current`.

---

## Suspected hotspots — investigate in this order

Each item lists the data path, the symptom we expect, and where to look. Order is
a rough priority guess; we confirm/reorder by what the profiler actually shows.

### TODO-TABS — first tab-switch hangs the switch animation (OPEN — fix not yet chosen)

- **Symptom:** first switch to each tab hangs the switch animation (later switches are
  fine) — `TabView` builds a tab's content lazily on first selection, so the first switch
  pays full view construction + `.onAppear`/`.task` data load synchronously mid-animation.
- **Baseline (macOS):** first-switch hitches — plan 192 ms, coach 158 ms, calendar
  281 ms (microhang). Later switches clean.
- **Finding:** confirmed via signposts (`tabSwitch` event, `ATP.load` span) this is
  framework view-graph construction volume, not our code — the plan tab's own work
  (`ATP.load` + our view bodies) is ~36 ms of the 192 ms; the rest is chart mark
  resolution/layout (~33 ms) plus thousands of small SwiftUI-internal updates (view-graph
  construction, glass materials, text styling). Same shape expected on coach/calendar.
  Caveat: trace is macOS — re-verify on the iPhone 17 Pro Sim before committing to a fix.
- **Fix options (undecided):**
  1. Defer tab content behind a lightweight placeholder on first switch, build real
     content ~one frame later — fixes all tabs generically, trades in a visible pop-in.
  2. Per-tab diet (fewer chart marks/glass layers, lazier sections) — no pop-in, but most
     of the cost is framework-internal volume with no single owner to cut.
  3. Diagnostic first: stub `ATPSeasonChart` out to confirm its exact share before
     choosing 1 vs 2.

### TODO-3 — PMC / Analytics recomputation
- **Path:** `PMCEngine` (CL/AL/FR EWMA over daily TL), `TrainingVolume.weeklyBuckets`,
  `WeeklyTarget`, `DashboardInsight` — all pure, recomputed on demand.
- **Symptom:** full-history EWMA recomputed for every view refresh with no memoization;
  recomputed inside view `body`. Known: `PMCEngine.current()` runs **twice** per
  dashboard load (TODO-2 follow-up, ~110 ms) — once directly, once nested inside
  `ATPEngine.current`; `refreshInsight` calls it a third time when the AI insight is on.
- **Look at:** whether results are cached/invalidated vs. recomputed; whether
  `PMCEngine.current()` walks the entire activity history each call.
- **Baseline:** _(time `PMCEngine.current()` with full dataset)_

### TODO-4 — ATP engine re-periodization
- **Path:** `ATPEngine`/`ATPPeriodization` re-periodizes after *any* ATP change;
  `ATPToolHandler.promptSection()` runs **every coach turn**.
- **Symptom:** full season re-periodization on small edits; promptSection cost paid on
  every message; ATP season chart (`ATPSeasonChart`) rebuild cost.
- **Baseline:** _(time a re-periodization; time promptSection)_

### TODO-5 — System-prompt build per turn
- **Path:** `CoachBrain` rebuilds `SYSTEM_PROMPT_TEMPLATE` each turn: date, memory
  `contextSummary`, data/devices section, PMC section, ATP `promptSection`.
- **Symptom:** repeated store reads + analytics on every single user message before
  the request even goes out → latency added to every coach reply.
- **Look at:** what's recomputed vs. cacheable between turns within a conversation.
- **Baseline:** _(time prompt assembly per turn)_

### TODO-6 — Tool-result projection & JSON serialization
- **Path:** `get_workouts` → `CoachActivityProjection` (lean view, detailed caps at 5
  laps) → `String(compactJSON:)`; all coach tool results serialize through CompactJSON.
- **Symptom:** large activity sets projected/serialized synchronously on main actor;
  number-formatting cost in CompactJSON; oversized payloads inflating token count
  *and* serialization time.
- **Baseline:** _(time a `get_workouts` all-status call on full dataset)_

### TODO-7 — SwiftData query patterns
- **Path:** `store.activities()`, `scheduledWorkouts`, `openScheduledWorkouts`,
  `PerformanceHistory.snapshot(asOf:)`, dedup.
- **Symptom:** fetch-everything-then-filter-in-Swift instead of predicates; faults
  firing during iteration; repeated identical fetches; `deduplicate()` cost.
- **Look at (SwiftData instrument):** fetch count per screen load, whether
  `detailsJSON`/`stepsJSON` blobs are decoded eagerly when not needed.
- **Baseline:** _(fetch count + duration for a Dashboard load)_

### TODO-8 — Stream parsing / normalization (ingest CPU)
- **Path:** sources shape raw samples → expand to ~1 Hz → `NormalizedStream.normalized`,
  `GradeAdjustedPace`, `HRZones` bucketing → `TLCalculator`.
- **Symptom:** per-sample work over long activities; re-expansion/re-decoding of
  streams; this is the heavy inner loop of ingest (ties into TODO-1).
- **Baseline:** _(time ingest of one long multi-hour activity)_

### TODO-9 — Garmin network I/O
- **Path:** `GarminService.fetchMetricHistory` (one range call per metric, concurrent),
  `fetchSleepStats` (≤28-day chunks), activity + scheduled-workout pulls.
- **Symptom:** serial vs. concurrent requests; over-fetching on resync; redundant
  pulls past the watermark; deep-backfill request count.
- **Look at (Network instrument):** request waterfall, count, retries.
- **Baseline:** _(request count + wall time for a resync)_

### TODO-10 — Chart & list rendering
- **Path:** `ATPSeasonChart`, PMC charts, Calendar `WeekTimeGridView`, Dashboard agenda,
  TrainingDetail.
- **Symptom (SwiftUI instrument):** heavy `body` recomputation, charts rebuilding all
  series on every data tick, large lists without identity stability, work done in
  `body` that belongs in the view model.
- **Baseline:** _(SwiftUI instrument: body count / longest body on scroll & refresh)_

### TODO-11 — Apple FoundationModels overhead
- **Path:** `CoachToolBridge` converts each tool's JSON-Schema → `GenerationSchema`
  **at runtime**; persistent `LanguageModelSession`.
- **Symptom:** schema rebuilt on every `setSources`/registry rebuild; per-turn bridging
  cost; first-token latency.
- **Baseline:** _(time tool-registry → GenerationSchema build)_

### TODO-12 — Main-actor pressure
- **Path:** `CoachBrain`, `DataSyncCoordinator`, `CoachMemory`, all tool handlers are
  `@MainActor`.
- **Symptom:** CPU-bound work (analytics, serialization, ingest scoring) running on the
  main actor and janking the UI; value-type DTOs crossing the actor boundary but the
  compute staying on main.
- **Look at:** what can move off `@MainActor` to a background context/task.
- **Baseline:** _(Time Profiler: main-thread time during sync + a coach turn)_

---

## Findings & decisions log

_(Append dated findings here as we work through items below TODO-2. Keep architectural
decisions that came out of profiling — e.g. "PMC memoized behind a version token",
"ingest moved to a background ModelActor" — so we don't relitigate them.)_

[2026-09-07] `PerformanceHistory.estimatedSeries` — baseline 514 ms → after 260 ms
(−49 %). Change: `snapshot(asOf:resolving:)` runs only the estimates a given series
needs. Tool: temporary Swift Testing harness on macOS, **Debug** (Release cannot host
`@testable import`, so these are an upper bound — Release will be several times
faster). Dataset synthesized to `ref/default.store` volumes: 233 resting-HR readings,
49 VO₂max, 42 run profiles, 118 ride profiles.

Why it was slow: `estimatedSeries(key)` re-evaluates `snapshot(asOf:)` on every date
its value can move (~290 for the VO₂max series), and `snapshot` resolved **all four**
estimates each time although the series consumes one. Half the cost was estimates
nobody asked for. Per key, all-four → own-plus-dependencies (FTP reads the resolved
VO₂max, LT pace the resolved LTHR):

| key | before | after |
|---|---|---|
| `vo2max_cycling` | 204 ms | 158 ms |
| `cycling_ftp` | 60 ms | 46 ms |
| `lactate_threshold_hr` | 44 ms | 4 ms |
| `lactate_threshold_speed` | 207 ms | 52 ms |

`latestSnapshot()` is 1.3 ms and was never the problem — the cost is `metricHistory()`,
which `PerformanceMetricsView.load()` runs for every metric on each
`trainingDataDidChange`.

**Still open, not yet measured against a target.** The residual 260 ms is dominated by
`vo2max_cycling` (158 ms): ~290 dates × a full top-20 selection over the whole effort
pool, rebuilt from scratch per date. The pool is the same on every date bar the tail —
an incremental or memoized form is the obvious next step, and needs its own baseline.
Anything that fires this on the main actor per user input has to debounce first: a
slider bound straight to `lt_pace_fraction_of_mas` wrote ~200 times per drag and made
the control unusable (fixed by committing on release, `RunningThresholdFactor`).

[2026-10-01] **Estimate pipeline — launch baseline** (macOS native, M1 Max, **Release**,
real store, dashboard only; signposts via a system-wide `xctrace` Time Profiler run).
New spans: `performanceHistory`, `PerformanceHistory.init`, `evidenceFetch`,
`latestSnapshot`, `estimatedSeries` (label = family), `metricHistory.sync`, `cpPosterior`,
`Metrics.load`, `PerformanceSettings.load`. **All of these were removed again after the
re-measure** — re-add them the same way to repeat it.

| span | thread | n | total | max |
|---|---|---|---|---|
| `syncAll` | main (awaiting network) | 1 | 1783 ms | — |
| `DashboardVM.load` | main | 5 | 934 ms | 259 ms |
| `performanceHistory` | main | 7 | 618 ms | 125 ms |
| `PMCEngine.current` | main | 10 | 470 ms | 133 ms |
| `estimatedSeries` (CP family) | background | 3 | 446 ms | 167 ms |
| `cpPosterior` | background | 315 | 442 ms | 3.8 ms |
| `latestSnapshot` | main | 4 | 270 ms | 112 ms |
| `deduplicate` | main | 1 | 100 ms | — |
| `evidenceFetch` | main | 4 | 78 ms | 20 ms |
| `PerformanceHistory.init` | main | 7 | 12 ms | 1.8 ms |

Findings:
- **The estimators are not the cost.** Both Kalman fits are 1.8 ms; one CP posterior is
  ~1.4 ms; the whole CP/W′/FTP series (105 dates) is 140–167 ms off the main thread.
- **`performanceHistory()` is fetch-bound**: 50 ms with the evidence cached, 110–125 ms
  without — of which the evidence fetch is 20 ms and the filter build 2 ms. The rest is
  the all-rows `PerformanceMetricRecord` fetch and the session-date fetch, repeated per call.
- **Values settle at ~3.9 s, in three waves** (`trainingDataDidChange` at 1.33 s after the
  activities ingest, 2.59 s after the scheduled sync, 3.74 s after `deduplicate`). Each
  wave drops every cache, rebuilds the resolver twice, restarts the CP series and reloads
  the dashboard (~180 ms main).
- A Debug build of the same launch: `DashboardVM.load` 315–430 ms, `PMCEngine.current`
  200–285 ms, and `deduplicate` waves until ~17 s.
- **Not measured yet:** the Statistics tab and Settings → Performance (`Metrics.load`,
  `PerformanceSettings.load`), the sync `metricHistory` callers, and any iPhone.

[2026-10-01] **Estimate pipeline — iPhone 15 Pro launch + Statistics tab** (device trace,
Time Profiler, 9.5 s; times are after launch, first signpost at 1.46 s).

| span | thread | n | total | max |
|---|---|---|---|---|
| `syncAll` | main (awaiting network) | 1 | 1840 ms | — |
| `Metrics.load` | main | 2 | 780 ms | 614 ms |
| `DashboardVM.load` | main | 4 | 616 ms | 221 ms |
| `estimatedSeries` | background | 10 | 573 ms | 237 ms |
| `performanceHistory` | main | 14 | 528 ms | 88 ms |
| `PMCEngine.current` | main | 12 | 401 ms | 87 ms |
| `latestSnapshot` | main | 4 | 146 ms | 66 ms |
| `PerformanceHistory.init` | main | 14 | 19 ms | 1.4 ms |

- Invalidation waves at 2.0 s (metrics ingest; no new activity), 3.4 s (scheduled sync)
  and 4.5 s (`deduplicate`). Statistics opened at ~4.2 s; its cards were final at **4.9 s**.
- The first `Metrics.load` (614 ms) was overtaken by the dedup wave and rerun (166 ms).
  The rerun is six resolver rebuilds at 25 ms each — every estimated series itself was
  under 8 ms, the CP family 92 ms.
- Two hangs: 487 ms at launch (`mapWarmUp` + first `DashboardVM.load`), 306 ms on the
  first switch to Statistics (TODO-TABS).

[2026-10-01] Estimate pipeline, resolver cache — launch, macOS Release, same scenario
(three invalidation waves, nothing new synced). Change: `performanceHistory()` keeps the
built resolver, its latest snapshot and its series tasks (`Resolved`) and a store write
only marks the rows unverified; the next read re-fingerprints them and keeps everything
when unchanged. Statistics cards fill per series, stored ones first. Tool: xctrace POI.

| span | baseline | after |
|---|---|---|
| `performanceHistory` | 7× / 618 ms | 4× / 479 ms |
| `PerformanceHistory.init` (filter fits) | 7× | 1× |
| `latestSnapshot` | 4× / 270 ms | 1× / 2 ms |
| `estimatedSeries` (CP family) | 3× / 446 ms | 1× / 144 ms |
| `DashboardVM.load` after a wave | ~180 ms | ~134 ms |
| first `PMCEngine.current` per load | 73 ms | 22 ms |

Open: the verification itself still costs 105–130 ms on the main thread per wave — the
re-fetch of every metric row and every session date (the evidence fetch is 14 ms of it).
Next candidate: fetch only the metric keys the resolver reads (it never touches the
sleep/wellness/zone series, ~80 % of the rows). iPhone and the Statistics tab not
re-measured yet.

[2026-10-01] `performanceHistory` verification — baseline 105–130 ms → after 70–78 ms
(−38 %). Change: the metric fetch is narrowed to `PerformanceHistory.readKeys` (the 13
series the resolver reads; an `assert` in `entry` catches a key read but not listed).
Tool: xctrace POI, macOS Release. Of the remaining ~71 ms the metric fetch is ~8 ms, the
evidence fetch 13 ms and the `date`-only session fetch ~50 ms — the next candidate.
Per wave the main thread now pays `deduplicate` 105–120 ms (remote-change waves only),
verification ~71 ms and `DashboardVM.load` ~135 ms; none of it is estimate maths.

[2026-10-01] Estimate pipeline, resolver cache — **iPhone 15 Pro** re-measure (launch,
then Statistics; same scenario as the device baseline above).

| span | baseline | after |
|---|---|---|
| `Metrics.load` | 614 ms, rerun 166 ms | 96 ms, rerun 11 ms |
| `performanceHistory` | 14× / 528 ms | 4× / 181 ms (37–60 ms each) |
| `latestSnapshot` | 4× / 146 ms | 1× / 1.5 ms |
| `estimatedSeries` CP family | 3 runs (92–237 ms) | 1 run (406 ms, during the sync) |
| `DashboardVM.load` after a wave | 137–144 ms | 112–122 ms |
| hangs | 487 ms launch, 306 ms tab switch | 431 ms launch |

Statistics cards were final ~0.1 s after the tab opened (baseline ~0.7 s). The single CP
series ran slower (one posterior at 43 ms) — `.utility` priority while the sync was busy;
it finished 1.7 s before the tab was opened.

[2026-10-01] **Dashboard Pinned CP card appears after ~6 s — Debug only.** Same launch,
macOS, temporary spans (removed again) around `StatisticsViewModel.loadMetrics`.

| span | Release | Debug |
|---|---|---|
| `estimatedSeries` CP family (105 posteriors) | 140 ms | **7366 ms** |
| `Stats.metric critical_power` (card data ready) | 349 ms, done 0.9 s after first signpost | 7366 ms, done 8.0 s |
| `performanceHistory` | 65–82 ms | 67–88 ms |
| resolver rebuilds | 1 | 1 |

The resolver cache holds (one rebuild, one series run per launch); the whole delay is the
CP posterior's grid loops compiled without optimisation, ~50× slower. The card is hidden
until its series exists, so it waits for all 105 dates although it shows one value.
Side finding (Release): two `DashboardVM.load` run back to back at launch (760 + 525 ms),
and the first marker's 1 ms series waits 476 ms for the main actor behind them.
