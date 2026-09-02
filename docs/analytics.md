# Analytics, charts & Statistics

Detail doc for `Analytics/`, `Shared/Charts/`, `Features/Statistics/`. Index: `CLAUDE.md` → Components.

## `Analytics/` — the pure, store-fed layer

No networking, no shared state; mostly `enum`/`struct` `static` functions over `WorkoutRecord` arrays.

- **`PMCEngine`** — CL/AL/FR from daily TL, TrainingPeaks EWMA.
- **`TL*`** — scoring / calculation / constants.
- **`ZoneModel`** — the single definition of a training zone. `ZoneMetric` (heart rate / power / pace) knows its bounds from a `PerformanceSnapshot` (%LTHR, %FTP, % of threshold *speed*) and the `detailsJSON` path its result lives at; `ZoneBucketing` buckets a source's raw stream against them. Bounds run on an axis that **rises with intensity**, so pace works in speed (m/s), not s/km. Sources never bucket — they hand over `ZoneSamples` and the store buckets at ingest (see `docs/store.md`), so every source reports the same distribution for the same workout.
- **`PowerCurve`** — max-mean power per log-spaced duration grid. Computed per ride at ingest from source-shaped 1 Hz segments into `WorkoutRecord.powerCurveJSON`, then aggregated as an element-wise max over a range for the Statistics chart and the coach's `get_power_curve`.
- **`TrainingLoadAnalytics`**, **`DashboardInsight`**.
- **`FTPEstimate`** — cycling FTP from `VO2max × mass × 0.0584`, for watches that never compute one (fēnix 6 and older). Garmin's auto-detected FTP is a near-deterministic linear function of the cycling VO2max the same watch reports (r ≈ +0.97, reproduced to 0.7 % out-of-sample); mass-scaling rather than a per-athlete intercept is what makes one constant transfer. Derived on read in `PerformanceHistory.snapshot(asOf:)` behind the `estimate_ftp_from_vo2max` opt-in — a measured `cycling_ftp` always wins, the estimate only fills a gap, and it is **never written into the metric series**. `PerformanceSnapshot.cyclingFTPIsEstimated` carries the provenance to the UI and the coach. Calibration and the rejected alternatives: `ref/ftp_lab/FINDINGS.md`.
- **ATP engine** — `ATPEngine`/`ATPPeriodization`/`ATPConstants`/`ATPSportSplit`, the season plan; CL via `PMCEngine`.
- **`WeeklyTarget`** — fed by the ATP: the current ATP week's TL is split across swim/bike/run by `ATPSportSplit` (the athlete's `sport_ratio`/`sport_floors` from `WeeklyStructure`), back-estimating each discipline's duration/distance. With no ATP yet it falls back to a flat hour-budget heuristic. Scheduled workouts only *raise* the goal.
- **`PlannedTL`** — estimates a planned workout's TL/duration/distance from its steps against a `PerformanceSnapshot`. Untargeted steps run on **one** assumption: done at `assumedIF × threshold speed` (CSS / threshold run pace; population typicals when unmeasured), which both converts time↔distance *and* is the step's IF — so a workout's estimated duration, distance and TL can never contradict each other.

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

**`WorkoutStreamChart`** plots one decoded `streamsData` metric over elapsed workout time, and takes optional `Band`s — shaded elapsed-time spans behind the trace, used by the multisport detail's race-wide charts to mark the legs. `WorkoutStreamModel.raceModels(segments:)` builds those race-wide models by placing every leg's stored bins on one race timeline; it combines **heart rate and elevation only**, because cadence, power and pace mean different things per discipline and one series across the legs would be a number that never existed.

**Every chart view renders a plain `Codable` value model with no store access** — colors resolve inside the view from semantic data via `Theme.Palette.sport(_:)` / `Theme.Palette.zones` — so the same views can be fed by a coach chart tool in chat.

Data comes from the pure Analytics layer:
- **`ZoneDistribution`** — the single reader/aggregator of the zone dicts, addressed through `ZoneMetric.detailsPath` so the schema is stated once. `ZoneDistributionStack` renders every metric that has data, so a new `ZoneMetric` surfaces in the detail view, Statistics and the coach's chat card at once. Pointing at a zone turns the bar's caption into that zone's readout (`ZoneMetric.rangeText`/`fractionText`) — the percent-of-threshold model always, the athlete's own bounds when known. It replaces the caption rather than floating above the bar: a `ChartTooltip` bubble stands taller than the whole bar block and would overflow the enclosing card. **The detail view shows the bounds the workout was bucketed against; the aggregates show today's, labelled `current thresholds`,** since a range can span a threshold change.
- **`ProportionBar`** — the shared segmented capsule. `selection` opts into scrubbing via `horizontalScrubbing` (the non-Chart sibling of `chartScrubbing` in `ChartScrubbing.swift`, same hover + long-press-drag inputs so a bar inside a ScrollView still scrolls); hit-testing reuses the *rendered* widths, since `max(2, …)` keeps a sliver visible and would otherwise disagree with the raw proportions.
- **`RampRate`** — weekly CL delta + the 5–8 CL/wk safe band; distinct from `TrainingLoadAnalytics`' per-sport volume ramp.

## Statistics screen (`Features/Statistics/`)

The single analysis screen, pushed from the dashboard's Statistics card (which shows this week's ΔCL, the ±15-day actual-vs-ATP-`planCurve` CL trend, and a mini sport-share bar; the whole card is the tap target). Contents: PMC stat cards + chart (`PMCInsightsSection`), ramp rate, sport share, time in zone, and the physiological-marker grid (`PerformanceMetricsSection`).
