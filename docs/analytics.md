# Analytics, charts & Statistics

Detail doc for `Analytics/`, `Shared/Charts/`, `Features/Statistics/`. Index: `CLAUDE.md` → Components.

## `Analytics/` — the pure, store-fed layer

No networking, no shared state; mostly `enum`/`struct` `static` functions over `WorkoutRecord` arrays.

- **`PMCEngine`** — CL/AL/FR from daily TL, TrainingPeaks EWMA.
- **`TL*`** — scoring / calculation / constants. The dispatch is power → pace → **heart-rate load**, and the HR path scores `Σ (HR/LTHR)² · seconds` over the stored readings rather than charging each zone at its midpoint. That matters because zone 1 is unbounded downward: at its 0.74 × LTHR midpoint a watch left running scores its stationary minutes as easy riding, which over-scored 53 of 205 real activities by more than 25 % and never once scored one *under*. Against Garmin's power TSS on 151 rides carrying both, the reading-level form fits at the same 0.77 scale with a median absolute error of 8.9 TSS versus 12.7. The zone buckets remain only for rows stored before histograms existed, and say so through `Basis.hrZones`.
- **`ZoneModel`** — the single definition of a training zone. `ZoneMetric` (heart rate / power / pace) knows its bounds from a `PerformanceSnapshot` (%LTHR, %FTP, % of threshold *speed*) and the `detailsJSON` path its result lives at; `ZoneBucketing` buckets a source's raw stream against them. Bounds run on an axis that **rises with intensity**, so pace works in speed (m/s), not s/km. Sources never bucket — they hand over `ZoneSamples` and the store buckets at ingest (see `docs/store.md`), so every source reports the same distribution for the same workout.
- **`PowerCurve`** — max-mean power per log-spaced duration grid. Computed per ride at ingest from source-shaped 1 Hz segments into `WorkoutRecord.powerCurveJSON`, then aggregated as an element-wise max over a range for the Statistics chart and the coach's `get_power_curve`.
- **`TrainingLoadAnalytics`**, **`DashboardInsight`**.
### `Analytics/Estimates/` — the thresholds the app works out for itself

Five files: the four estimators plus `RecencyWeighting`, which holds the Cauchy age
kernel and the weighted quantile they share. They are grouped because they form one
chain — VO₂max feeds FTP, LTHR feeds the LT-pace fraction — and because they are the
only part of `Analytics/` that *replaces* a value the athlete's watch reported, which is
what makes each of them carry an `EstimateConfidence` rather than a bare number. All
four resolve on read in `PerformanceHistory.snapshot(asOf:)` behind their opt-ins; none
is ever written into the metric series.

- **`VO2maxEstimate`** — cycling VO₂max reconstructed from ordinary rides, for watches that compute none and athletes who will not ride a maximal test. Åstrand-Ryhming with power in place of an ergometer load: each sustained effort's oxygen cost (ACSM leg ergometry) scaled up by the heart-rate reserve left unused. The scaling is against *reserve* (`%HRR ≈ %VO2R`), which normalises for resting HR so the gate tracks the athlete's working range rather than sliding whenever HRmax is corrected. One reading per (ride, duration) over the 8–30 min band, **normalised to 480 s** because the same ride reports a lower VO₂max at 30 min than at 8 — HR lags at 8 and has drifted by 30, and without the correction every aggregate is decided by the shortest bin. Aggregated as the **age-weighted mean of the best 20 readings** (Cauchy kernel, τ = 90 d): selecting by *value* makes added easy volume inert — a quantile over the pool is a quantile over how much easy riding happened lately — while the kernel still lets the number fall as good efforts age. The count is absolute on purpose; a fraction of the pool would grow with volume and reintroduce the dilution. Evidence is stored per ride as `WorkoutRecord.submaxProfileJSON` (duration → best mean power + the HR held across those same seconds), not a finished VO₂max, so a corrected HRmax/mass re-resolves history. Returns an `EstimateConfidence` with the value.
- **Running VO₂max** (`VO2maxEstimate.running(mas:)`) — **not a second estimator, a change of unit.** `LTPaceEstimate` already scales grade-adjusted speed by the unused heart-rate reserve, which *is* the `%VO2R` scaling in m/s (the ACSM running equation's base is `VO2_REST`, so it cancels); this only applies the economy equation, `VO₂ = 0.2 · v(m/min) + 3.5`. The vertical term is deliberately absent — the input is grade-adjusted, so the hill is already priced into `v`. Consequence: `LTPaceEstimate.estimate` returns **MAS**, and the two run thresholds read that one number, so they can never describe different athletes. Own opt-in `estimate_running_vo2max_from_runs`, because a watch may report a usable VO₂max and no threshold pace. Derivation: `ref/threshold_lab/running/vo2max.py`.
- **`FTPEstimate`** — cycling FTP as `VO₂max × mass × 0.0582`, where the constant is the published chain `0.22` (gross efficiency, Jobson) × `0.76` (fraction of VO₂max at threshold) × `20.9/60` (W per ml O₂/min, Péronnet & Massicotte). Derived rather than fitted to one watch's output, which is what lets it transfer to an athlete it was never calibrated on; mass-scaling rather than a per-athlete intercept is what makes one constant serve everyone. Its input is `VO2maxEstimate`. **No per-athlete term, unlike the run**: the fraction of heart-rate reserve the two reference athletes hold at cycling threshold differs by 1.2 % — worth 2 W, inside the ±2 W the FTP back-solve itself carries — against 8.4 % running. Derived on read in `PerformanceHistory.snapshot(asOf:)` behind the `estimate_ftp_from_vo2max` opt-in (which gates the VO₂max reconstruction too) — a *manual* reading always wins, the estimate otherwise **replaces** the synced value, and it is **never written into the metric series**. Calibration and the rejected alternatives: `ref/threshold_lab/cycling/FINDINGS.md`.
- **`ZoneHistogram`** — the per-workout `value → seconds` distribution, encoded lzfse into `WorkoutRecord.zoneHistogramData` at ingest. Time in zone depends only on how long each value was held, never on the order samples arrived in, so re-bucketing the re-expanded histogram against new thresholds reproduces a full re-ingest **exactly** — which is what makes *Recompute history* honest. Heart rate and power bin losslessly (integers); grade-adjusted speed bins at 1 cm/s.
- **`LTHREstimate`** — lactate-threshold HR for watches that never detect one. Friel's 30-minute-time-trial protocol taken opportunistically from real training: `steadyWindow` finds the best *flat* 20-minute mean HR per activity (≤ 0.15 bpm/min — a rising window means the athlete was above threshold — and starting within the first 40 min, since accumulated cardiac drift inflates even a flat window later). Those efforts are then gated to the ones hard enough to inform a threshold and reduced by a **recency-weighted 75th percentile** (Cauchy kernel, τ = 180 d, 365-day window). **HRmax is an input**, taken from the `max_hr` series; age formulas under-predict trained athletes by 7–19 bpm and are not used. Three properties are load-bearing and each replaced something that was measurably wrong: *(1)* **sport-filtered** — the app estimates the *running* LTHR, because cycling LTHR runs 5–10 bpm lower in the same athlete and a pooled value read one reference athlete's May ride as his running threshold, 6 bpm high; *(2)* **not a maximum** — a raw max lets one hot day or one mis-read window set the value and, inside the window, never fall again; *(3)* **carry-forward, not a floor** — with no qualifying effort the last real answer is held as `.stale` rather than replaced by `0.85 × HRmax`, which is a different quantity and drew a 7 bpm cliff through a training break. The fraction stands only when nothing has *ever* qualified, as `.rough`. On a power sport `Gate.power` gates on watts instead — intensity is measured there, and a heart-rate gate cannot separate a threshold effort from a bad strap. **The cycling LTHR is a second, separate value** (`lactate_threshold_hr_cycling`, opt-in `estimate_cycling_lthr_from_rides`), because cycling LTHR runs 5–10 bpm under running LTHR in the same athlete and no watch publishes it — Garmin's is Firstbeat's, detected while running. Every heart-rate consumer reads `PerformanceSnapshot.thresholdHR(for:)`, never `lactateThrHR` directly: `ZoneMetric.upperBounds`, `TSSCalculator` (the HR-load fallback) and `PlannedTSS`. With no cycling value the running one answers — the athlete's own LTHR on record, not a population constant. The power gate's reference is *relative* (85 % of the athlete's own best 20-min power in the window), which is what makes it strap-proof and also what makes it degenerate when the window holds no hard effort: the hardest easy ride becomes its own reference and the aggregate settles on a jogging heart rate — on real data eight months at 151–162 bpm (73–79 % of HRmax), labelled `.anchored`, until one 297 W test moved it to 170.9 in a day. `minimumFractionOfHRMax = 0.80` therefore **refuses** an aggregate that low; it clears both reference athletes' measured cycling values (0.830 / 0.816) and is inert on the heart-rate gate, whose efforts already clear 0.84. `steadyHR20` + `peakHR` are stored at ingest **unfiltered**, so correcting a wrong HRmax re-filters the whole history without re-ingesting.
- **`LTPaceEstimate`** — running LT pace for athletes who cannot produce a benchmark effort. Follows the literature's `LT = LT% × MAS` (r = 0.95, SEE 4.0 %), reconstructing **MAS from ordinary runs** by scaling grade-adjusted speed with the unused heart-rate reserve: `MAS = GAP / %HRR`. Because `%HRR ≈ %VO2R` the cost-of-running term cancels — the athlete's own economy is folded in rather than assumed, which is what a VO₂max→pace map gets wrong. Every 60-s block inside 80–95 % HRmax contributes, **provided its HR is not still climbing** (≤ 2 bpm/min): a lagging block overstates the reserve left unused and reads high, and admitting only settled blocks is what makes the constant below mean what it says instead of silently absorbing the lag. Each run reduces to its own best reconstruction and the **75th percentile across runs** is taken, so a long session cannot outvote a short one by bucket count. **`fractionOfMAS` is a property of the athlete, not a population constant** — it is the fraction of heart-rate reserve held at threshold ÷ 1.035 pool inflation, and the two reference athletes sit at 0.799 and 0.869, 8.4 % apart and worth 21 s/km on the one whose heart rate is capped. It is **derived from the athlete's own resolved LTHR** (all three inputs are already known) with `lt_pace_fraction_of_mas` as an override for someone who has measured it in a threshold test; `PerformanceSnapshot.ltPaceFractionUsed` surfaces what was actually applied. Being an athlete constant it is **resolved once, from the values in force now, and used for every date** — re-deriving it per date folds the LTHR series' own trajectory into the *shape* of the pace series, where only its scale belongs (176 → 184 → 182 bpm over one real season is 6.8 % of fraction, ~20 s/km, that no run ever showed). Published on a 1 s/km grid — the display resolution, nothing more: quantising to the smallest worthwhile change instead (~1.5–2 %, i.e. 4–6 s/km) makes a value on a cell boundary flip the whole cell width on sub-noise movement, which is the artifact a change threshold exists to prevent; suppressing an unearned change needs hysteresis on the change, not a coarse grid on the level. **Runs only** — a triathlon or brick leg carries a pace and a heart-rate stream like any run but not the relation the reconstruction rests on: after hours of prior work heart rate no longer tracks the metabolic cost, so `MAS = v / %HRR` reads high, and the pool inflation the fraction divides by is calibrated on runs alone. One race leg in a 90-day window moved a real athlete's peak 12 s/km. A run must hold **≥ 6 settled blocks** (≥ 16 min) before it says anything: below that its "best" block is whichever two or three minutes happened to be quickest, and on a real season one 14.8-minute run held the highest MAS of the whole dataset and decided the estimate for two months. Needs **≥ 3 qualifying runs** in 90 days; below that the last window that held enough is carried **forward unchanged**, and the series marks it (`MetricPoint.confidence`; anything but `.anchored` is `isProvisional` and drawn dashed) rather than decaying it — a detraining decay is a second model layered on a value that already has no evidence behind it, and it was worth 9.7 % (~30 s/km) of movement no run ever showed. A window under **7 runs** answers as `.thin` rather than `.anchored`: the p75 index is `0.75 × (n − 1)`, so at n = 5 and n = 9 it is a whole number and the "quantile" is one session — appending a single run at the *top* of a real January pool, with nothing existing getting faster, moved the answer 24 s/km. Raising `minimumRuns` is not the cure (at 5 and 6 the largest nine-day step is *worse*, 28–29 s/km); reporting the window's own thinness is. Evidence is stored per activity as `WorkoutRecord.paceHRProfileJSON`. Opt-in `estimate_lt_pace_from_runs`. **Do not blend it with a VO₂max map**: that scores well only against Garmin's own VO₂max-derived value and is 7× worse against an independent race anchor. Derivation and the rejected markers: `ref/threshold_lab/running/FINDINGS.md`.
- **ATP engine** — `ATPEngine`/`ATPPeriodization`/`ATPConstants`/`ATPSportSplit`, the season plan; CL via `PMCEngine`.
- **`WeeklyTarget`** — fed by the ATP: the current ATP week's TL is split across swim/bike/run by `ATPSportSplit` (the athlete's `sport_ratio`/`sport_floors` from `WeeklyStructure`), back-estimating each discipline's duration/distance. With no ATP yet it falls back to a flat hour-budget heuristic. Scheduled workouts only *raise* the goal.
- **`PlannedTL`** — estimates a planned workout's TL/duration/distance from its steps against a `PerformanceSnapshot`. Untargeted steps run on **one** assumption: done at `assumedIF × threshold speed` (CSS / threshold run pace; population typicals when unmeasured), which both converts time↔distance *and* is the step's IF — so a workout's estimated duration, distance and TL can never contradict each other.

**`StrengthSets`** — the one set model (`SetRow`) behind the strength table, for a plan and a recorded session alike. `blocks(planned:)` keeps the plan as written — a circuit is one block with its rounds and round rest, a rest step its own item. `rows(performed:)`/`entries(_:)` convert to and from the stored `strength.exercises` (the athlete's edits round-trip through them). `comparison(planned:performed:)` pairs each recorded set with the prescribed set it matches, on Garmin's own exercise key (never on name similarity; each exercise's sets consume its prescribed sets in order, so interleaved circuit rounds line up), adds every prescribed set nothing was recorded for after the last line of its exercise, and flags only a paired set whose prescribed rep count came back missing or different. Improvising is not a discrepancy. Pinned by `TriGeniusTests/Analytics/StrengthSetsTests.swift`.

### `Analytics/Tissue/` — the second load axis

A completed strength session keeps whatever HR-derived TL it scored, like any session,
but its *structural* cost is a second axis: a heavy 5×5 barely lifts heart rate while
placing the week's largest structural demand, and a kettlebell circuit does the reverse.

So every session — swim, bike, run **and** strength — maps onto tissue groups, and
each group carries a forecast of **when it is clear for hard work again**. That forecast
is the primary value in every surface; the load levels behind it are the evidence.

- **`TissueModels`** — thirteen groups (`TissueGroup`), an ordinal `LoadLevel` 0–4 that is
  never shown as a percentage, and `TissueDayState`: one group's morning, with muscle
  and an optional tendon.
- **`TissueLoadModel`** — real sessions → forecasts, conflicts, the planned week, drivers
  and the 6-week history (below). `TissueSession` carries each session's dose per group.
- **`TissueLogic`** — `clearDay` / `clearLabel` / `cardRows` / `freeGroups` /
  `chronicStatus` / `chronicRows`. Pure and pinned by `TriGeniusTests/Analytics/Tissue/`.
- **`TissueLeadLine`** — the card's headline, a decision tree over fixed templates.
- **`CoachTissueContext`** — what the coach is handed when the athlete asks about a
  group: snake_case keys, calendar days, coarse confidence. The coach explains and
  offers options; it never re-derives any of these numbers.

Four things are load-bearing:

1. **Today is `todayIndex`, never `days[0]`.** A forecast carries 3 past days before today and
   the 7 days from today on (`TissueMetrics.pastDays` / `aheadDays`); the card, the grid
   and the group detail draw all of them. Everything that means "this morning" or "from
   now on" reads `TissueForecast.today` / `.ahead` — `clearDay`, `cardRows`, the lead
   line, the coach context — never an index of its own.
2. **Ties go to the tendon.** A tendon at or above Moderate governs even when the muscle
   matches it, because it clears more slowly and it is the one that decides whether a
   hard session can happen. A tendon below Moderate never governs.
3. **Unknown load is not modelled (for now).** A strength session without exercises
   (Apple Health reports only its duration) carries no dose, and there is no hatch or
   repair prompt — deferred in `TODO_KRAFTTRAINING.md`. With no model uncertainty either,
   a clear forecast is a single day ("Tue", "Now", "Later"); ranges return with Phase 5's
   confidence. A group with no data at all is absent.
4. **The card's rows are stable.** `cardRows` takes `previouslyListed` and keeps a group
   that was shown yesterday until it clears, so the dashboard does not reshuffle between
   two groups that tie. Ties otherwise fall back to the anatomical order of `allCases`.

### The model (`TissueLoadModel`)

Computed on the fly at dashboard load (`TissueCardModel.Input.live`, the one place the
Tissue Load surfaces read the store) over ~9 weeks of completed sessions and the next 9
days of plan; nothing is persisted. Every constant lives in **`TissueConstants`**
(`Analytics/Tissue/TissueConstants.swift`), provisional until Phase 5 calibrates it — the
sport weights for Shins and the arm groups are general-knowledge placeholders.

1. **Dose.** An endurance session doses each group with its TL × a per-sport weight,
   muscle and tendon apart (`TissueConstants.enduranceWeights` — running loads the lower
   leg's tendons hardest, swimming the shoulders and arms). Multisport rows dose per leg
   (`sportContributions`). A strength session doses in **hard sets**: 1 per set on a primary
   group, ½ on a secondary, times `tlPerHardSet` to share a scale with TL, plus tendon dose
   on a primary group with a modelled tendon when the library marks the exercise
   `loadsTendon`. Its HR-derived TL never enters this axis. A plan doses from its planned
   TL or prescribed sets. A set's groups resolve in one place (`TissueSession.groups`);
   `TissueSession.targets` reads the same groups as primary/secondary for the muscle map
   (`Shared/Charts/MuscleMap`) at the top of the strength card, plan and session alike.
2. **Decay.** A morning state is every earlier dose decayed exponentially — muscle τ 1 day,
   tendon τ 3 days.
3. **Levels, relative to the athlete.** A morning state is divided by that group's own
   average morning state over the last 28 days (floored at `baselineFloor`): < ½ Fresh,
   < 1 Light — clear for hard work — < 1½ Moderate, < 2 Loaded, else Heavy.
4. **Conflict = a load spike** (replaces handoff D4's key/hard rule). A planned session
   conflicts when it would push a group it loads (≥ 25 % of its largest group dose) above
   that group's highest post-session state of the last 30 days × 1.1 — tendon first —
   whether or not the group was clear that morning. Earlier sessions the same day stack.
   No conflicts until 4 weeks of history exist. The lead line reads "Tue run: Achilles
   load spike."
5. **Key session** = the window's heaviest planned session (total dose) — the ring on the
   card's day header and the taper rows. Plans carry no key flag.
6. **Chronic** — each of the last 6 full weeks' muscle dose per group against its own
   6-week average; nil until six weeks of history exist.

Previews run the same model over synthetic weeks (`TissuePreviewFixture`, DEBUG only).

**Muscle groups come from Garmin's catalog** (`GarminMuscles`, bundled as
`Assets/Exercises/garmin-muscles.json` from `ref/garmin_api/exercises/Exercises.json`):
~1500 exercises keyed by category + name, every one of Garmin's 17 muscles folded onto a
group — abs/obliques → Low back (the group that replaces "Core / low back"), chest →
Shoulders, abductors → Glutes, lats/traps → Upper back, biceps/triceps/forearm to their
own groups. Garmin names no shin muscle, so Shins takes no strength load. The library resolves
its groups through it, so a recorded set of an exercise outside the library gets groups
too; the library still carries `loads_tendon`, and its own groups for the 6 exercises
Garmin lacks.

**`ExerciseLibrary`** (`Analytics/Tissue/ExerciseLibrary.swift`) — ~60 curated strength
exercises loaded once from bundled `Assets/Exercises/exercise-library.json`, each mapped
onto the `TissueGroup`s it primarily/secondarily loads and whether it stresses a tendon
(handoff decision D8). Picker data for the workout editor (`Features/WorkoutEditor/`),
not coaching prose — that's why it lives as JSON rather than in `Assets/Knowledge/`. A
step can reference none of these (a free-typed custom exercise); it then contributes no
tissue-group evidence.

**`StrengthProfile`** (`Analytics/Tissue/StrengthProfile.swift`) — the athlete's strength
setup (handoff flow 7): a training `Place` that fixes the allowed `Exercise.Equipment`, and
the `Area`s to work around, each excluding every exercise that loads its `TissueGroup` as a
primary *or* secondary mover (D10: exclusion only). `allows(_:)` is the one filter the
exercise picker, the editor's default exercise and `get_exercises` all apply, so an excluded
exercise never reaches the athlete's library or the model. Experience is the `strength`
sport profile's level. Stored on that profile's `SportProgressRecord` (`trainingPlace`,
`excludedAreas`; `CoachMemory`, `docs/coach.md`). Pinned by `StrengthProfileTests`.

### Per-sport aggregation goes through `sportContributions`

`WorkoutSegment.swift` carries the two accessors every per-sport reader uses instead of `SportFamily(sportKey: record.sport)`:

- **`record.sportContributions`** → `[(family, tss, distanceKm, durationMinutes)]` — the row itself for a single-sport workout, one entry per leg for a multisport session. A brick therefore counts as one bike session *and* one run session, each with its own load.
- **`record.detailDicts`** → the single-sport details dicts the row holds (its own, or one per leg) — what any reader of the `detailsJSON` schema iterates.

There is deliberately **no `.multisport` `SportFamily` case**: the family is the bucket key iterated with `allCases` in `WeeklyTarget`, `TrainingLoadAnalytics`, `SportShareChart` and `ATPSportSplit`, so a sixth case would create a phantom bucket in every ring and chart — and it would be wrong, because a brick's load genuinely belongs to bike + run.

Segment-aware readers: `TrainingVolume.weeklyBuckets` (which is what feeds sport share), `WeeklyTarget.projection`'s completed loop, `TrainingLoadAnalytics.longest(in:family:)`, and `ZoneDistribution.aggregate(records:source:family:)` — the last takes the discipline as a parameter and applies it *per details dict*, so only the matching leg of a session counts.

The `WorkoutRecord` display bridge (`PlannedWorkoutStructure.swift`) is `@MainActor` — it feeds the estimators the store's cached `latestSnapshot()`. `resolvedTargetTL`/`plannedDurationMinutes`/`plannedDistance` are the single planned-value resolvers every reader (rows, weekly targets, PMC forecast, insights) goes through.

## `Shared/Charts/` — the reusable chart layer

`ProportionBar`, `ZoneDistributionBar`, `PMCStatCard`, `SportShareChart`, `RampRateChart`, `CLTrendChart`, plus `ChartScrubbing.swift`.

**`ChartScrubbing.swift`** provides the shared `chartDateScrubbing(_:snap:)` hover/touch modifier — `chartXSelection` on iOS, pointer hover via `chartOverlay` on macOS. Each chart passes a `snap` quantizing the raw location to its data grid, and the binding is written only on change, so a hover event re-collects the chart's marks once per data point crossed instead of per pixel. `ChartTooltip` is the readout every chart renders at the scrubbed date.

**`WorkoutStreamChart`** plots one decoded `streamsData` metric over elapsed workout time. Its geometry is **not** in the view: `Analytics/StreamPlot.swift` owns the bucketing, the axis model (`Axis.linear`/`.inverse` — one description replacing the per-kind `display`/`isMoving`/`format` conversions that used to be restated in four switches), the `Domain` the axis spans, the `Rescale` that puts an overlay on someone else's scale, and the zone a bucket sits in. All of it is deterministic arithmetic with real edge cases, so it is pinned by `StreamPlotTests`; the view only renders. **The smoothing window is derived from pixels, not seconds**: the chart reports its own width and the bins are averaged into buckets ~4 pt wide, floored at the stored bin width. One rule then settles every scale — an 8-hour ride on a phone averages minutes, the same ride in a Mac window far less, a 30-minute run seconds, and a zoomed-in span dissolves back to the raw bins. Each bucket also carries the raw min/max it hides, drawn as a faint `AreaMark` band behind the trace and spelled out as a `Range` row in the tooltip, so the smoothing never quietly swallows the spread. A `reference` on the model (currently the **stored** normalized power on a bike power trace — read, never recomputed from the downsampled bins) draws as a dashed rule. Where the workout carries zone bounds (`ZoneDistribution.zoneBounds` — the ones it was *bucketed* against, so the colors and the time-in-zone bars can never disagree) a **zone ribbon** runs along the bottom of the plot: `StreamPlot.zoneRuns` merges adjacent buckets of one zone into stretches (never across a recording gap), and each is drawn in its zone color. Its thickness is a constant 6 pt, converted to domain units through the measured plot height (`chartPlotStyle` + `onGeometryChange` reports the plot rect, whose width also sets the smoothing bucket) — as a *share* of the plot it swallowed the full-size sheet. Resting the pointer on the ribbon — `chartScrubbing`'s `footer`/`inFooter`, a Bool so vertical movement re-collects the marks on entry and exit rather than per pixel, with a 26 pt hit strip over the 6 pt ribbon — shades **every** stretch of that zone full height and dims the rest of the ribbon, answering "where else did I ride this hard?"; the value tooltip stands down while that is being read. The chart reports the zone up through a `highlight` binding (from `onChange`, after the update, since it is derived from the same bucketing the marks come from), and the detail sheet names it beside the total duration — bounds from `ZoneMetric.rangeText`, seconds from the model's stored `zoneSeconds`, both as bucketed at ingest rather than counted off the buckets on screen. It sits *left* of the total so naming a zone never shifts it. The trace itself keeps the metric's own color. A bucket's zone is the one it spent the most **time** in, not the one its mean falls in — over a long bucket a surging effort averages into a zone barely ridden — with a tie going to the easier zone. Counting bins weights by time because the bins are uniform, and one count serves every metric, since every zone model runs on an axis that rises with intensity: pace included, whose bounds are speeds. A bin without a reading is **not** automatically a pause: sources record irregularly (Garmin's smart recording leaves 1-8 s between samples, so most bins carry none of their own), so the last reading is held across the empty bins and only a silence longer than `StreamPlot.holdSeconds` (30 s, the same cap `ZoneBucketing.durationSamples` uses) breaks the trace. Elevation (`Kind.bridgesGaps`) holds across any pause, being a level the athlete still has where power or pace is not; a reading *below* an inverting axis's floor is the athlete standing still, which breaks the trace at once. Area and line use separate series keys so neither bridges a break by accident.

**`WorkoutStreamCard`/`WorkoutStreamDetail`** (`WorkoutStreamDetail.swift`) are the tappable card and the sheet it opens: the same chart at full size, panned by dragging and zoomed by pinch or by the sheet's buttons (what a mouse has). `WorkoutStreamChart.Zoom` owns all of that arithmetic — window clamping, re-centring on the midpoint, the floor of 20 stored bins — so the gestures and the buttons cannot drift apart. **Zoom is not magnification**: it narrows the visible span the smoothing window is derived from, so pulling in uncovers the raw bins. The sheet also offers every *other* metric of the same workout as an `overlay` — heart rate against the climb it was earned on — bucketed on the same grid and drawn as a silhouette behind the trace. Its own domain is mapped linearly onto the primary's, and there is deliberately **no second Y axis**: two metrics sharing a plot are not comparable and an axis would imply they are, so the overlay's real numbers live in the tooltip and in the range the picker states beside it. Panning moves `chartXScale`'s domain rather than using `chartScrollableAxes`, which only pans on a *horizontal* scroll event — something a plain mouse never sends, so a scrollable chart is unpannable on macOS. On iOS the pan stands down while a long press is scrubbing; macOS scrubs on hover, which is never a drag. The card also carries an expand button next to its title: the plot's scrub overlay is a UIKit view, so a tap landing on it is not guaranteed to reach the card's own gesture. On macOS the sheet takes most of the window via `\.windowSize` (`Shared/DesignSystem/WindowSize.swift`, published by `measuringWindow()` on the scene root) and follows it on a resize. SwiftUI hands a sheet nothing about its window — `PresentationSizingContext` is empty and every `presentationSizing` option resolves to a fixed size, `.fitted` (the macOS default) to the smallest its content accepts — so the size is measured where it is known and passed down the environment. iPadOS needs the opposite treatment: a frame cannot resize a sheet there (the presentation owns the size) and the default is `.form`, small and centred, so that side takes `.presentationSizing(.page)`.

`WorkoutStreamChart` also takes optional `Band`s — shaded elapsed-time spans behind the trace, used by the multisport detail's race-wide charts to mark the legs. `WorkoutStreamModel.raceModels(segments:)` builds those race-wide models by placing every leg's stored bins on one race timeline; it combines **heart rate and elevation only**, because cadence, power and pace mean different things per discipline and one series across the legs would be a number that never existed.

**Every chart view renders a plain `Codable` value model with no store access** — colors resolve inside the view from semantic data via `Theme.Palette.sport(_:)` / `Theme.Palette.zones` — so the same views can be fed by a coach chart tool in chat.

Data comes from the pure Analytics layer:
- **`ZoneDistribution`** — the single reader/aggregator of the zone dicts, addressed through `ZoneMetric.detailsPath` so the schema is stated once. `ZoneDistributionStack` renders every metric that has data, so a new `ZoneMetric` surfaces in the detail view, Statistics and the coach's chat card at once. Pointing at a zone turns the bar's caption into that zone's readout (`ZoneMetric.rangeText`/`fractionText`) — the percent-of-threshold model always, the athlete's own bounds when known. It replaces the caption rather than floating above the bar: a `ChartTooltip` bubble stands taller than the whole bar block and would overflow the enclosing card. **The detail view shows the bounds the workout was bucketed against; the aggregates show today's, labelled `current thresholds`,** since a range can span a threshold change.
- **`ProportionBar`** — the shared segmented capsule. `selection` opts into scrubbing via `horizontalScrubbing` (the non-Chart sibling of `chartScrubbing` in `ChartScrubbing.swift`, same hover + long-press-drag inputs so a bar inside a ScrollView still scrolls); hit-testing reuses the *rendered* widths, since `max(2, …)` keeps a sliver visible and would otherwise disagree with the raw proportions.
- **`RampRate`** — weekly CL delta + the 5–8 CL/wk safe band; distinct from `TrainingLoadAnalytics`' per-sport volume ramp.

## Statistics screen (`Features/Statistics/`)

The single analysis screen, pushed from the dashboard's Statistics card (which shows this week's ΔCL, the ±15-day actual-vs-ATP-`planCurve` CL trend, and a mini sport-share bar; the whole card is the tap target). Contents: PMC stat cards + chart (`PMCInsightsSection`), ramp rate, sport share, time in zone, and the physiological-marker grid (`PerformanceMetricsSection`).
