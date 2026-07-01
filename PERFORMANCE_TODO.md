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
> **Reference hardware** (host: M1 Max):
> - **iPhone 17 Pro Simulator** on the M1 Max — primary baseline for the iOS UI/widget paths.
> - **macOS (M1 Max) directly** — for the pure compute paths (analytics, ingest, sync,
>   serialization) where a native run measures cleaner than the simulator.
> - Pick whichever measures more reliably per item; run **both** when a result is
>   device-specific (e.g. SwiftUI/Chart rendering can differ sim vs. native). Note which
>   one a baseline was taken on in the result log.

### Result log format

When closing an item, append a line:

```
[YYYY-MM-DD] <item> — baseline <X> → after <Y> (<−Z%>). Change: <what>. Tool: <instrument>.
```

---

## TODO-0 — Instrument the app (prerequisite for everything below)

There are currently **no `os_signpost` markers in the codebase** — we're profiling
blind. Before chasing individual hotspots, add lightweight signposts around the
suspect spans so the Instruments timeline names them for us.

- [ ] Add a shared signpost log (`OSLog(subsystem: "net.Narica.TriGenius", category: .pointsOfInterest)`).
- [ ] Wrap the high-level spans: `DataSyncCoordinator.syncAll`, per-source `sync`,
      `ingest`, `PMCEngine.current()`, `ATPEngine` re-periodization, `DashboardViewModel.load`,
      system-prompt build, tool-result serialization.
- [ ] Verify markers appear under "Points of Interest" in a trace.
- **Finding:** _(none yet)_

---

## TODO-CAL — Calendar tab (KNOWN SLOW — start here after TODO-0)

User-reported: the Calendar is **generally very slow**. This is our first concrete
target once signposts are in.

- **Path:** `Features/Calendar/` — `CalendarView` → `CalendarViewModel` →
  `WeekTimeGridView` (the week time-grid) + `CalendarNavBar`. Observes
  `trainingDataDidChange`.
- **Symptom to confirm:** slow tab open, janky week scrolling/swiping between weeks,
  lag after a sync or workout edit.
- **Likely suspects:** full `store.activities()` / scheduled-workout refetch on every
  appearance and every `trainingDataDidChange`; per-cell layout work in `body`
  (time-grid positioning recomputed for all events on each render); date math /
  filtering done in `body` instead of precomputed in the view model; no row identity
  stability causing full grid rebuilds; eager decode of `detailsJSON`/`stepsJSON` blobs
  for events that are only rendered as blocks.
- **Profile with:** SwiftUI instrument (body count / longest body during tab open and
  week swipe) + Time Profiler + SwiftData instrument (fetch count per appearance).
  Run on **iPhone 17 Pro Sim**; cross-check rendering on **macOS** if sim-specific.
- **Baseline:** _(measure: tab-open time, body count on one week-swipe, fetch count)_
- **Finding:** _(none yet)_

---

## Suspected hotspots — investigate in this order

Each item lists the data path, the symptom we expect, and where to look. Order is
a rough priority guess; we confirm/reorder by what the profiler actually shows.

### TODO-1 — Cold launch & first sync
- **Path:** `TriGeniusApp` launch → `DataSyncCoordinator.syncAll(readSources)` →
  per-source sync → `ingest` (TSS scoring) → `reconcileWriteTarget`.
- **Symptom to check:** time-to-interactive on launch; main-thread block while the
  first sync/ingest runs; UI frozen on a populated DB.
- **Likely suspects:** ingest scoring loop runs per-activity with a
  `PerformanceHistory.snapshot(asOf:)` lookup each time (O(activities × metrics)?);
  sync ordering forces metrics-source before activities (serial); is any of this on
  the main actor?
- **Baseline:** _(measure: launch → first frame, and syncAll duration)_

### TODO-2 — `trainingDataDidChange` fan-out (recompute storms)
- **Path:** any store mutation posts `trainingDataDidChange` → observed by Dashboard,
  Calendar, ATP, PerformanceMetrics, PlannedWorkoutDetail views.
- **Symptom:** one ingest/edit triggering N full recomputes across views; redundant
  `store.activities()` fetches; coalescing not actually coalescing.
- **Look at:** `DashboardViewModel.load` re-runs `store.activities()` + `PMCEngine.current()`
  + `TrainingVolume.weeklyBuckets` on every change — is the whole PMC recomputed from
  scratch each time? Is each observing view doing its own full fetch?
- **Baseline:** _(count recomputes per single workout edit; time one `load`)_

### TODO-3 — PMC / Analytics recomputation
- **Path:** `PMCEngine` (CTL/ATL/TSB EWMA over daily TSS), `TrainingVolume.weeklyBuckets`,
  `WeeklyTarget`, `DashboardInsight` — all pure, recomputed on demand.
- **Symptom:** full-history EWMA recomputed for every view refresh with no memoization;
  recomputed inside view `body`.
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
  `GradeAdjustedPace`, `HRZones` bucketing → `TSSCalculator`.
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

_(Append dated findings here as we work through items. Keep architectural decisions
that came out of profiling — e.g. "PMC memoized behind a version token", "ingest moved
to a background ModelActor" — so we don't relitigate them.)_
