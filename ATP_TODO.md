# ATP_TODO.md — Annual Training Plan (TrainingPeaks ATP clone)

Working TODO for rebuilding TrainingPeaks' **Annual Training Plan (ATP)** in TriGenius.
Bugs live in `BUGS.md`, general future work in `FEATURES.md`; this file is scoped to the ATP build-out only. Check items off as they land.

## What the ATP is

A **season-long, event-anchored, periodized plan of weekly training volume** that ramps the athlete's fitness (CTL) toward priority events and tapers into them. It sits *above* individual scheduled workouts: the ATP sets a **weekly TSS target** per week of the season; daily/weekly scheduling fills that target in. TrainingPeaks computes it deterministically (no AI) from a setup wizard, then renders a season chart (stacked weekly TSS bars + projected CTL/ATL/TSB curves) and a per-week periodization table.

## Scope for this first step (decided with the user)

- **Two volume methodologies only:** `Weekly TSS` and `Target CTL` (TP calls the latter "Event Fitness (CTL)"). The third TP option (`Weekly hours`) is **out of scope**.
- **Generation = hybrid.** Build the **deterministic periodization engine first** (the faithful TP clone). Layer coach access on top afterwards: the AI coach can generate/regenerate/tweak the ATP via tools, but the math is deterministic and testable.
- **Events = essentials only:** name, date, ATP event type, A/B/C priority. The TP "Edit Goals" screen (time/distance/place/PR/custom) is **deferred** — goals don't drive the periodization math.
- **Storage = new SwiftData models** in `TrainingDatabase` (`default.store`), alongside `WorkoutRecord` / `PerformanceMetricRecord`. Integrates with the existing PMC / `WeeklyTarget` analytics that already read SwiftData.
- **UI = replaces the current `Plan` tab** (`Features/Plan/PlanView.swift`, registered in `RootTabView` at `TriGeniusApp.swift:118`). See the migration section — the current phase editor and the `set_training_plan` tool / `CoachMemory.trainingPlan` phase model need a migration decision.

## Resolved decisions

- **ATP replaces the phase model.** The ATP is the single source of truth for season planning. `CoachMemory.trainingPlan` (`targetEvent`, `eventDate`, `phases[]` with per-sport `SportTarget`) is superseded — phases become a *view* derived from the ATP's period column where `ProactiveCoach` / `PhasePresentation` still need them.
- **`set_training_plan` tool + `Phase`/`PhaseName`/`SportTarget` get removed.** Replaced by the ATP models + ATP coach tools (Milestone 6). Migration of any existing in-memory phase data into an ATP is optional cleanup, not a blocker.
- **Multiple events per ATP from day one.** A/B/C events; the engine periodizes backward from each A event and chains blocks between them (`3_ATP.png` shows two marathons + a triathlon in one season).
- **Rolling horizon, no `endDate`.** The plan window is `[startDate (anchor), last event]` and grows when an event is added — TP itself only periodizes to the last race (everything after is "Not-Set" CTL decay, not a planned region). `startDate` / `startingCTL` stay as the projection anchor so plan-CTL vs actual-CTL stays comparable — the plan is *not* re-anchored on today's CTL daily.
- **`ATPConfig` is a singleton.** One athlete ⇒ one plan, so no `name` / `isActive` / `atpId` anywhere — it's "the config that computes target TSS".
- **Weeks are derived, never stored.** Only inputs persist (`ATPConfig` + events + sparse overrides); the engine recomputes the full weekly grid on demand (≈52 weeks of EWMA is cheap — memoize later only if a profile demands it). One manual lever: a whole-week `pinnedTSS` override; the engine owns periodization.
- **CTL is daily — three derived curves** (plan / detraining / actual), all from `PMCEngine` with different input. Never stored, never on the weekly row; the table samples the daily curve at week-end for its CTL columns.
- **Tuning constants centralized + calibrated against TP.** All ATP shape constants (period TSS multipliers, easiest/hardest spread, taper depth/length by priority, recovery drop) live in one documented `Analytics/ATPConstants.swift` — the engine's single source, no magic numbers in the engine. They are *fit, not guessed*: a `ref/atp_lab/` sandbox (mirroring `ref/tss_lab/`, not in the build) ingests a large set of TP example plans and tunes the constants so our weekly-TSS output matches TP, then the numbers are hand-ported into `ATPConstants.swift` (`PORTING.md` discipline). **Needs the TP example plans as machine-readable data** (weekly TSS + periods + events per plan) — to be collected. Calibration runs on the **sport-agnostic** weekly TSS, which is *why* the per-sport split must stay a separate downstream layer (next item).
- **Per-sport TSS split = downstream layer (approach A).** The ATP core stays sport-agnostic (one weekly TSS, TP-faithful + calibratable). A separate pure `ATPSportSplit` (`Analytics/`) divides the week's TSS across swim/bike/run/strength by an **athlete sport ratio + optional per-sport floors** (e.g. a swim floor for a bike-heavy athlete). Period-constant for now; period-dependent emphasis is a later upgrade (approach B — emphasis multipliers in `ATPConstants`). The ratio/floors are an athlete preference → extend `WeeklyStructure` in `CoachMemory`, **not** `ATPConfig`. This layer is what feeds `WeeklyTarget` (Milestone 5).

## Still open (flag, don't guess)

- [ ] **Units.** App is metric (`DESIGN`/CLAUDE: km, m/s). TP tables list weekly *hours* and *miles*; we only use **TSS** and **CTL**, so conversion is mostly avoidable — don't surface the hours/miles columns.
- [ ] **`currentFitnessLevel` (Strong/Weak) is not modeled.** TP's calibration plans set it and it visibly reshapes the early-base ramp (a Weak athlete starts lower and ramps slower), but `ATPParams` has no counterpart. The golden test `09_fitness_weak` stays un-matchable until this is decided — add a field to `ATPConfig`/`ATPParams` and feed it into the weekly-TSS shape, or rule it out of scope. Flag before guessing a shape model.

---

## Milestone 1 — Data model (SwiftData)

Three small `@Model`s. **The weekly grid is derived, never stored** (recomputed by the engine — Milestone 2). CTL/ATL/TSB are **daily** series, so they live in none of these models.

- [x] `ATPConfig` `@Model` — **singleton** ("the thing that computes target TSS"; one athlete ⇒ one plan, so no `name` / `isActive`): `startDate` (anchor for the plan-CTL projection), `startingCTL: Double?` (nil ⇒ derive from PMC at `startDate`; a stored seed only when the plan starts without history), `methodology` (`weeklyTSS` | `targetCTL`), `recoveryCycle` (`3` | `4`), `maxRampRate` (CTL/wk ceiling, default `7`), `weeklyAverageTSS` (the **only** Weekly-TSS input — easiest/hardest week + annual are derived by the engine, not stored). **No `endDate`** — the horizon rolls to the last event.
- [x] `ATPEvent` `@Model`: `id`, `name`, `date`, `eventType` (enum, Appendix C — the **duration bucket lives here**, driving the Appendix B suggestion), `priority` (`A`|`B`|`C`), `targetCTL: Double?` (Target-CTL anchor + dashed target line; nil otherwise), `notes` (free-text description; gives the coach context). Detailed goals (time/place/PR) deferred — they don't drive the math. No `atpId`.
- [x] `ATPWeekOverride` `@Model` — **sparse**, one row per week the athlete pinned: `weekStart` (Monday, `@Attribute(.unique)` key), `pinnedTSS: Double` (hard constraint; `0` = rest/vacation), `note`. The engine solves the free neighbours around each pin. No `atpId`.
- [x] Value DTOs crossing the actor boundary into the pure engine (`Ingested*`-style `Sendable` structs): `ATPParams`, `ATPEventInput`, `ATPWeekOverrideInput`.
- [x] Store API on `TrainingDataStore` (not scattered): reads → DTOs (`atpParams()`, `atpEvents()`, `atpOverrides()`); writes (`saveATPParams`, `upsertATPEvent`, `deleteATPEvent`, `setATPOverride(weekStart:pinnedTSS:)`, `clearATPOverride(weekStart:)`). Every mutation posts `trainingDataDidChange` (existing convention) so derived views recompute.

## Milestone 2 — Periodization engine (pure, testable)

A pure `enum`/`struct` layer in `Analytics/` (no networking, no SwiftData types) over value DTOs — matches the existing analytics style. **Reuses `PMCEngine` for all CTL math** (single EWMA core, per the CLAUDE non-negotiable — never re-implement the EWMA). The ATP layer only produces weekly TSS + a daily TSS map and feeds `PMCEngine`.

Output DTOs: `ATPPeriod` (enum: base1/2/3, build1/2, peak, race, transition), `ATPWeekShell` (period layout, pre-TSS), `ATPWeekPlan` (one **weekly** row: `weekStart`, `period`, `periodWeekIndex`, `isRecovery`, `isTaper`, `plannedTSS`, `rampRate` (ΔCTL vs prev wk), `weeksToNextEvent`, `nextEventID`, `pinned` flag — **no CTL fields, those are daily**), and `ATPPlan` (the bundle the UI renders: `weeks: [ATPWeekPlan]` + the three daily CTL series below).

- [x] `ATPPeriodization.layout(params:events:today:) -> [ATPWeekShell]`: lay period blocks **backward from each A/B event** (Transition → Race → Peak → Build 2/1 → Base 3/2/1), insert recovery weeks every `recoveryCycle`, mark `isTaper` in the weeks before A/B events (**C events ignored**). Horizon = last event date (+ short transition tail).
- [x] **Weekly-TSS mode** — `ATPEngine.weeklyTSS(shells:params:overrides:) -> [ATPWeekPlan]`: shape TSS across the season per period (build weeks ramp toward the derived hardest, recovery weeks toward the derived easiest, taper before A/B), honouring `pinnedTSS` as hard constraints and redistributing the slack to the free neighbours so the average/annual holds. Easiest/hardest = `weeklyAverageTSS × spread` constants (not stored). Compute per-week ramp.
- [x] **Target-CTL mode** — `ATPEngine.targetCTL(shells:params:events:overrides:) -> [ATPWeekPlan]`: back-solve the weekly TSS so the projected CTL hits each A/B event's `targetCTL` on its date (inverse of the PMC EWMA), bounded by `maxRampRate`, with recovery + taper, honouring pins (redistribute the deficit to free neighbours).
- [x] **Core identity / sanity check:** steady-state `weeklyTSS ≈ CTL × 7` (`290 ↔ 40`, `740 ↔ 105`, … — confirmed by the reference tables). Defaults and cross-checks.
- [x] `ATPEngine.dailyPlannedTSS(weeks:scheduled:) -> [Date: Double]` — spread each week's `plannedTSS` across its training days. **The seam to PMC**: reconcile with reality the way `WeeklyTargets` does — where real scheduled/completed workouts exist use them, the ATP weekly budget only tops up the rest (`max(planned, budget)`) — so the near-term forecast and the far-term plan agree instead of double-counting.
- [x] **Three daily CTL series, all via `PMCEngine` (extend it, don't duplicate):**
  - **plan CTL** — EWMA from (`startDate`, `startingCTL`) over the full-season `dailyPlannedTSS`. Generalise `PMCEngine.project` to take an explicit anchor + a full (not future-only) daily map (or add `PMCEngine.simulate(anchor:dailyTSS:through:)`).
  - **detraining CTL** — pure decay from today's actual CTL with TSS = 0 ("if you stop training"); a small `PMCEngine.decay(from:through:)`.
  - **actual CTL** — existing `PMCEngine.compute` over completed activities.
- [x] `ATPEngine.build(params:events:overrides:history:scheduled:today:) -> ATPPlan` (pure) orchestrates the above; `ATPEngine.current(store:today:) -> ATPPlan?` is the `@MainActor` convenience that reads the store + `PMCEngine.current` actuals and returns the bundle — mirrors `PMCEngine.current` / `WeeklyTargets.targets`. No new stateful store.
- [x] `ATPSportSplit.split(weeklyTSS:ratio:floors:) -> [SportFamily: Double]` (pure, approach A) — the **only** sport-aware piece: divide a week's TSS by the athlete sport ratio, lift each sport to its floor, re-normalise. Ratio/floors from `WeeklyStructure` (`CoachMemory`). The sport-agnostic core stays untouched (keeps TP calibration valid).
- [x] **Starting-CTL estimation** helper (TP "Estimate Starting Fitness"): avg weekly hours + sport → estimated CTL (Cyclist ≈7, Triathlete ≈8, Runner ≈9 CTL per weekly hour — Appendix A), to seed `startingCTL`; plus "use my current CTL" from `PMCEngine` when enough history exists.
- [x] **Suggested-volume helper**: `ATPConstants.suggestedVolume(for: ATPEventType)` → weekly-TSS / target-CTL ranges (Appendix B). Wired into the wizard: a "Suggested … TSS"/"Suggested … CTL" hint + **Apply** (midpoint) under the weekly-average field (Weekly-TSS mode, keyed off the season's last A event) and under the event editor's Target CTL field (Target-CTL mode).
- [x] **Ramp-rate guardrail** (TP's unsustainable-ramp flag): `ATPWeekPlan.rampExceeded` (= weekly ΔCTL > `maxRampRate`, previously a dead input) flags weeks in the season chart (red ⚠︎ over the bar + a summary notice). Flag only — no auto-smoothing (would fight the pin redistribution; revisit if wanted).
- [x] Engine pinned by golden-master tests in `TriGeniusTests/Analytics/` (`ATPPeriodizationTests`, `ATPEngineTests`, `ATPSportSplitTests`, + `simulate`/`decay` in `PMCEngineTests`). `targetCTL_planCurveHitsTarget` validates the back-solve → CTL end-to-end.
- [x] **Numeric calibration harness against real TP plans** — `TriGeniusTests/Analytics/ATPGoldenTests.swift` (see *Calibration harness* below). Currently **failing on purpose**: the corpus is in, the engine isn't fit yet, so every plan reports its full gap. Fitting `ATPConstants.swift` until these pass is the open calibration work.

### Calibration harness (`ATPGoldenTests.swift`)

Golden-master tests that drive the engine against the real TrainingPeaks plans collected in `ref/atp_lab/data/plans/*.json` (the config + events we sent TP, and the weekly `volume`/periods TP returned). The whole point is to make the calibration miss **legible**, not to pass yet.

- **One parameterized case per plan** (`atpWeeklyVolumeMatchesTrainingPeaks`): maps the plan's `atp_config_sent` / `events_sent` / `pins` → engine DTOs, runs `ATPPeriodization.layout` → `ATPEngine.weeklyTSS` (the `targetCTL` branch is wired but the current corpus is all `atpType:"TSS"`), pairs each engine week to TP's `volume` by Monday. A second test `atpGoldenFixturesPresent` fails loudly if the corpus is missing.
- **Failure prints the whole series**, not one cell: the plan's config header, then a week-by-week table (date · engine period · TP period · engineTSS · tpTSS · Δ), then the aggregates **mean-abs-error, signed bias, RMSE, max-abs**.
- **Single acceptance threshold** — `ATPGoldenTolerance` (`maxMeanAbsError`, `maxRMSE`, raw TSS). One place to set "how close to TP counts as matching"; tighten it as the engine is fit.
- **Fixtures are read from disk** (located by walking up from `#filePath` to `ref/atp_lab/data/plans`), **not bundled** — consistent with `ref/` staying out of the build. They're git-ignored (`data/*.json`), so the harness is **local-only**; a fresh checkout regenerates the plans via `ref/atp_lab/` before these run. (Open: trim + commit a representative subset if we want this in CI — the JSON is mostly `performanceActuals` we don't read.)
- **Filtering (`ATPGoldenFilter`)** — the corpus is heading past 60 plans, so the run set can be narrowed by these keys (unset ⇒ all; combine freely): `ATP_FITNESS` (Strong/Weak), `ATP_EVENTS` (exact count), `ATP_METHOD` (TSS/CTL), `ATP_DIM` (dimension substring), `ATP_NAME` (plan/file substring). Swift Testing `@Tag`s can't do this — they attach to the test function, not to individual data-driven arguments — so the filter narrows the `arguments:` list at collection time instead. **`xcodebuild` scrubs the shell environment**, so a CLI `ATP_FITNESS=… xcodebuild test` prefix never reaches the runner; two channels are honoured instead: set the keys in the **Xcode scheme** (Test ▸ Arguments ▸ Environment Variables — forwarded), or, for the CLI, drop a `key=value`-per-line file at **`ref/atp_lab/.atp_test_filter`** (git-ignored; an env var wins over the file; delete it ⇒ all plans).

## Milestone 3 — Setup wizard UI

Rebuild TP's "Create an Annual Training Plan" flow (`1_Training Plan - Weekly TSS.png`, `1_Training Plan - Event Fittness.png`). Use `Theme`/`Surfaces` per `DESIGN.md`.

> **Built as a single editable form** in a new **ATP tab** (`Features/ATP/ATPTabView.swift`), not a paged wizard — a throwaway-free test surface alongside the existing Plan tab (replacement is Milestone 4/5). Suggested-volume pre-fill omitted (deferred to M3 cleanup with the `eventType` enum). Edit → **Save** → `ATPEngine.current()` recomputes → the season chart below updates live.

- [x] **Step 1 — Methodology picker:** `Weekly TSS` vs `Target CTL` (segmented). (Omit Weekly hours.)
- [x] **Step 2 — Details:** (name/endDate dropped per the model; start date, recovery cycle 3/4, starting-CTL = "use current fitness" toggle or manual) ATP name, date range (default ~1 year), periodization Automatic/Manual, current-fitness selector, recovery cycle (every 3 / every 4 weeks).
- [x] **Step 3 — Volume:**
  - Weekly TSS mode: weekly average, easiest week, hardest week, approx annual (auto-computed), starting CTL.
  - Target CTL mode: starting CTL + "Adjust Other Parameters" (collapsible: ramp limits etc.).
- [x] **Step 4 — Events:** add/edit/remove events (name, date, type, priority; + `targetCTL` field in Target-CTL mode, as in the Event-Fitness screenshot). Reuse the essentials event editor.
- [x] "Save ATP" → persist `ATPConfig` + `ATPEvent[]` (weeks are derived, not stored) → engine recomputes.
- [x] Edit/regenerate an existing ATP (the form loads the stored config; Save re-runs the engine). Per-week manual overrides (`ATPWeekOverride`) UI still to come.

## Milestone 4 — ATP view (replaces Plan tab)

Rebuild the ATP screen (`3_ATP.png`): season chart on top, periodization table below.

- [x] **Season chart** (`Features/ATP/ATPSeasonChart.swift`): weekly **TSS bars** (planned grey + completed) on the left axis, the three **CTL curves** (plan / actual / detraining) dual-axis-scaled on the right, the **Form (TSB) curve** (amber area + dashed ATP / solid actual, sharing the CTL scale), the **period band** (colored period blocks below the baseline), and event markers (A/B/C) on the timeline. Weeks are **drag-pinnable** (manual TSS override; reset on Save).
- [ ] **Periodization table**, one row per week: Week (date range), Weeks-to-Event, Event, Priority, Period (colored chip: Base/Build/Peak/Race/Transition + week #), planned TSS, Completed (from `ActivityRecord`), Ramp Rate, projected CTL ATP/Actual, projected Form ATP/Actual. Match TP's column set; "Details" column deferred.
- [x] **Actual vs plan** (chart): completed weekly TSS bars + actual CTL curve overlaid on the ATP projection (`ATPPlan.completedTSSByWeek` + `actualCurve`, both from the store via `ATPEngine.current`). Per-week table actuals still pending.
- [ ] Manual-edit affordances (Manual periodization): edit a week's TSS / period inline; recompute downstream projection.
- [x] Empty state: hint to set volume + add an A/B event then Save.
- [~] Register in `RootTabView` — added as a **separate `RootTab.atp` tab** for now (test alongside Plan). Replacing `PlanView` / reusing `RootTab.plan` is the later cleanup (Milestone 5).

## Milestone 5 — Integration & migration

- [ ] **Retire the phase model.** Remove `set_training_plan` + `Phase`/`PhaseName`/`SportTarget` from `CoachMemory`; derive any phase view `ProactiveCoach` / `PhasePresentation` still need from the ATP's period column. (Migrating existing in-memory phase data into an ATP is optional.)
- [ ] **Feed `WeeklyTarget`** from the ATP's current-week TSS via `ATPSportSplit` (approach A — ratio + floors). Replaces the current phase/heuristic split in `WeeklyTargets`; the rings then fill against the ATP's per-sport target.
- [ ] **`ProactiveCoach`**: surface ATP context (current period, this week's TSS target vs projection, weeks-to-A-event, ramp-rate sanity) into the system-prompt section.
- [ ] **Coach memory `contextSummary`**: inject a compact ATP summary (active ATP name, current period, target CTL for next A event) — the hybrid plan's "summary into prompt context" wiring.

## Milestone 6 — Coach (AI) integration (hybrid layer, after the engine works)

- [ ] Tool(s) for the coach to **read** the ATP (`get_atp` → current plan, weeks, events, projections).
- [ ] Tool(s) to **create/regenerate/adjust** the ATP via the deterministic engine (`set_atp` / `adjust_atp` — coach supplies events + methodology params, engine computes; coach never hand-writes weekly numbers). Snake_case params, JSON-Schema dict, works for both backends per CLAUDE.md.
- [ ] Remove `set_training_plan` (decided) — superseded by the ATP create/adjust tools above.
- [ ] Knowledge: a draft `TRAININGSPLAN.md` exists at the repo root (built so far only from the two TP help-center pages — starting-CTL table + volume ranges; periodization methodology still flagged MISSING, pending the user's two WIKI pages). When complete, move it to `Assets/Knowledge/TRAININGSPLAN.md` and wire into `knowledgeFiles` / `read_knowledge`. (Separate from this engine; the engine is deterministic.)

## Milestone 7 — Docs

- [ ] Update `CLAUDE.md` architecture section (new SwiftData models, ATP engine layer, Plan-tab replacement, WeeklyTarget source change) **in the same change** that ships them.
- [ ] Add the `TRAININGSPLAN.md` coach-knowledge file (above) if approved.

---

## Appendix A — Reference: Estimated Starting CTL by weekly hours

From TP "Estimate Starting Fitness (CTL)" (last ~2 months of training). Linear per weekly hour:

| Hours/wk | Cyclist | Triathlete | Runner |
|---|---|---|---|
| per hour | ≈7 | ≈8 | ≈9 |
| 1 | 7 | 8 | 9 |
| 5 | 35 | 40 | 46 |
| 10 | 70 | 80 | 91 |
| 15 | 105 | 121 | 137 |
| 20 | 140 | 161 | 183 |

(Full table 0–22 h available in the screenshot; values are an estimate to seed `startingCTL`.)

## Appendix B — Reference: Suggested Weekly TSS & Target CTL

From TP "Suggested Weekly TSS and Target CTL". Note **Weekly TSS ÷ 7 ≈ Target CTL** throughout (steady-state identity used by the engine).

**Triathlon**
| Event | Weekly TSS (low–high) | Target CTL (low–high) |
|---|---|---|
| Sprint | 290–740 | 40–105 |
| Standard (Olympic) | 390–880 | 55–125 |
| Half-Distance | 490–980 | 70–140 |
| Full-distance | 590–1470 | 85–210 |

**Cycling**
| Event | Weekly TSS | Target CTL |
|---|---|---|
| Road Racing | 290–1230 | 40–175 |
| Century / Metric (≤6h, complete) | 290–740 | 40–105 |
| Gravel/Fondo (competitive/6h+) | 490–1230 | 70–175 |
| MTB XCO | 290–980 | 40–140 |
| MTB Marathon (3–6h) | 390–1230 | 55–175 |
| MTB Ultra (6h+) | 390–1230 | 55–175 |

**Running (by duration)**
| Event | Weekly TSS | Target CTL |
|---|---|---|
| 5k–10k | 220–820 | 35–135 |
| Half-Marathon | 330–990 | 55–160 |
| Marathon | 440–990 | 70–160 |
| Ultra | 550–1100 | 90–180 |

**Other (Nordic ski, rowing, other multisport — by "A" race duration)**
| Duration | Weekly TSS | Target CTL |
|---|---|---|
| Up to 3h | 290–880 | 40–125 |
| 3–8h | 390–1080 | 55–155 |
| 8h+ | 490–1230 | 70–175 |

## Appendix C — Reference: periods, ramp rate, ATP table columns

- **Periods** (chip colors from `3_ATP.png`): Base 1/2/3, Build 1/2, Peak, Race, Transition — each labeled with its week index (e.g. "Base 3 · Week 2"). Recovery weeks fall at the end of each period block per the recovery cycle.
- **Ramp Rate** = weekly change in CTL (positive in build, ~0/negative in recovery & taper). TP flags unsustainably high ramp.
- **ATP table columns** to reproduce: Week (date range) · Weeks to Event · Event · Priority (A/B/C) · Period · TSS (planned) · Completed · Ramp Rate · Details(*deferred*) · Fitness (CTL) ATP · Fitness (CTL) Actual · Form (TSB) ATP · Form (TSB) Actual.
- **ATP Event Types** seen / to enumerate (e.g. "Triathlon (2–4 hrs)"): build the enum from TP's event-type list — capture the full list when wiring the event editor.

## Source screenshots

`ref/TrainingPeak Screenshots/ATP/` — `0_Add Event*.png` (event + goals editors), `1_Training Plan - Weekly TSS.png` / `1_Training Plan - Event Fittness.png` (wizard, the two in-scope modes), `3_ATP.png` (final ATP view), and the two TP help-center pages (starting-CTL + suggested-TSS tables, transcribed in appendices A/B).
