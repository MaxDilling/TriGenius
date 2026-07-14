# Coach-Grounding: Training Plan — Periodization & Volume (ATP)

**Purpose:** the season-plan mechanics — weekly TSS shaping, block lengths, ramp-rate math, taper
factors, recovery-week depth — are already computed by the ATP engine and surfaced every turn via
the `=== ANNUAL TRAINING PLAN (ATP) ===` system-prompt section, and in full via `get_atp` (config,
events, current period, ramp warnings). **Do not re-derive those numbers** — read them from the
tool. This document is the judgment layer on top: *why* the periodization is shaped this way, how
to individualize the engine's `recovery_cycle` / `max_ramp_rate` / `starting_ctl` inputs to `set_atp`,
how to advise on taper and event sequencing, and which red flags should make the coach intervene.
General coaching behavior — data checks, communication standards, clinical-escalation rules — is in
the system prompt; consult this file whenever the ATP itself (not a single workout) is under
discussion.

---

## 1. Periodization phases — what each block is for

The engine's ladder (`base1 → base2 → base3 → build1 → build2 → peak → race`, consumed backward
from each A event) follows Friel/TrainingPeaks: general-to-specific, "the closer to the race, the
more the workouts must become like the race."

| Period | Purpose | CTL trend |
|---|---|---|
| Base 1/2/3 | Aerobic foundation, muscular force, technique; the primary CTL-accumulation phase | Building |
| Build 1/2 | Race specificity — muscular endurance → threshold → anaerobic/VO2max; sessions become "mini-races" | Building, then plateauing |
| Peak | Sharpen: hold intensity, cut volume, shed fatigue | Plateau / slight decline |
| Race | Freshness + race-touch intensity; taper completes | Declining (intended) |
| Transition | Post-event recovery, unstructured cross-training | Falling (intentional detraining) |

**Intensity distribution shifts with the block**, not just volume: Base is the most polarized
(≈80% low intensity / ≈20% threshold+high, Seiler & Kjerland 2006); Build shifts toward pyramidal —
more time near threshold as race pace approaches; Peak/Race preserve intensity while stripping
volume. Keep *some* of every intensity in every phase — the old "Base = only easy, Build = only
intervals" split isn't supported (Friel: two decades of looking, no study shows anaerobic work
nullifies base aerobic gains).

**Block periodization (Issurin)** — concentrated single-target ~2–4 week blocks
(Accumulation → Transmutation → Realization) — is a legitimate advanced/elite alternative to the
linear ladder above. Treat as opt-in for experienced athletes who explicitly want it, not a default
suggestion; it demands more load concentration and recovery capacity than the linear model.

---

## 2. Seeding a new plan: starting CTL & realistic volume

**`set_atp`'s `starting_ctl`** is optional and *should stay omitted whenever the athlete already has
synced training history* — the engine derives it from their actual recorded CTL on the plan's anchor
date, which is always more accurate than an estimate. Only supply an explicit `starting_ctl` for an
athlete with **no usable history yet** (brand-new to the app or to structured training):

- Estimate from average weekly training hours over the last ~2 months: **≈7 CTL/hour (cyclist),
  ≈8 (triathlete), ≈9 (runner)** — roughly linear, higher for running because it carries more TSS
  density per hour (TrainingPeaks "Estimate Starting Fitness").
- Treat the result as a rough seed, not a measurement — **distrust CTL/ATL/TSB readings for the
  first 4–6 weeks** until real completed-workout TSS has accumulated; say so to the athlete rather
  than presenting it as settled.

**Picking `weekly_average_tss` (weekly_tss methodology) or a `target_ctl` (per A/B event)** — use as
a sanity range, not a hard rule, when the athlete has no better anchor (e.g. no prior personal best
CTL for this distance):

| Event | Weekly TSS | Target CTL |
|---|---:|---:|
| Triathlon — Sprint | 290–740 | 40–105 |
| Triathlon — Olympic | 390–880 | 55–125 |
| Triathlon — 70.3 | 490–980 | 70–140 |
| Triathlon — Full | 590–1470 | 85–210 |
| Cycling — road race / century | 290–1230 | 40–175 |
| Cycling — gravel/fondo/MTB marathon | 390–1230 | 55–175 |
| Running — 5k/10k | 220–820 | 35–135 |
| Running — half marathon | 330–990 | 55–160 |
| Running — marathon | 440–990 | 70–160 |
| Running — ultra | 550–1100 | 90–180 |

Identity worth knowing for explaining the numbers: at steady state **weekly TSS ÷ 7 ≈ CTL** (CTL is
a 42-day EWMA of daily TSS) — this is why the two columns above line up, and why the two ATP
methodologies (§7) are two views of the same thing.

---

## 3. Ramp rate — individualizing `max_ramp_rate`

The engine defaults `max_ramp_rate` to **7 CTL/week** and flags any week that exceeds it
(`ramp_warnings` in `get_atp`, an inline ⚠️ in the prompt section) — but the *right* number is
individual. Adjust it via `set_atp` rather than leaving the default unquestioned:

- **Novice / <1 yr structured training / returning from injury or a long break:** 3–5.
- **Experienced with an established base:** 5–8 (TrainingPeaks/Friel's "about right for most" is
  5–8; above 8 "often leads to injury, illness, or burnout").
- **Elite / short intentional overload block:** briefly >10, never sustained beyond ~1 week,
  followed by forced recovery.
- **Higher current CTL tolerates a higher absolute ramp** than the same number applied to a low-CTL
  athlete (Vance): a 9-TSS/week increase is trivial at CTL 150, crippling at CTL 40. Prefer the low
  end of the band as CTL climbs toward the athlete's own ceiling (§9) — the ramp naturally flattens
  there since CTL is an EWMA.

**When to intervene regardless of what `max_ramp_rate` is set to:**
- Sustained ramp >8–10 CTL/week, or `ramp_warnings` > 0 for more than one week running.
- TSB (from the PMC section) sustained below −30, or below −20 more than once per ~10 days
  (Fitzgerald's TSB-management parameter).
- CTL flat or declining two consecutive weeks *outside* a planned taper — investigate missed
  sessions, under-recovery, or life stress before assuming detraining.
- Physiological: resting HR persistently 5–10 bpm above baseline, or HRV suppressed beyond ~72 h —
  cross-check via `get_metric_history` (resting HR / HRV); the system prompt's HRV/RHR interpretation
  and clinical-escalation rules apply as-is.

---

## 4. Recovery cadence — individualizing `recovery_cycle`

The engine inserts one lighter week every `recovery_cycle` weeks (default 4, at ~60% of the block's
load) at the end of each Base/Build block. Set it to:

- **3** — age ≥50, novice, high life stress, or an athlete showing slow recovery (elevated RHR,
  suppressed HRV, or subjective fatigue stacking across a block).
- **4** — the default; fits most athletes under ~50 with an established base.

A recovery week only needs to be **3–5 days lighter**, not the whole week — the engine's ~40–50%
volume cut already reflects that. When *filling* that week's sessions (via `add_workouts`), keep one
or two short intensity touches rather than cutting intensity to zero — durability and neuromuscular
sharpness fall off faster than aerobic fitness during a full week of only-easy work.

---

## 5. Taper & event priority

The engine already tapers automatically: `peak`/`race` periods run lighter (≈80%/40% of block load),
plus a further ≈70% factor in taper weeks, for **2 weeks before an A event, 1 before a B, 0 before a
C** — this is sport-agnostic and uniform across the plan. What it does *not* do, and what the coach
should apply when discussing or filling that plan's actual sessions:

- **Target Form (TSB) on race day**, as a sanity check on how the taper feels: roughly **+5 to +10**
  for a short-course race (sprint/Olympic), **+10 to +20** for a 70.3, **+15 to +25** for a full
  Ironman/marathon. Above ~+25 the athlete has over-tapered (fresh but flat, losing fitness); some
  athletes genuinely perform best only barely positive (+5–10) — this is individual, learn it from
  how the athlete has raced before.
- **Preserve intensity, cut volume and (a little) frequency** — this, not resting more, is what the
  evidence supports (Bosquet 2007 meta-analysis: 2-week taper, volume down 41–60%, intensity and
  frequency essentially unchanged, is the best-evidenced protocol; ~2–3% performance gain). Cutting
  intensity during a taper is detraining, not tapering.
- **Discipline-specific weighting within a triathlon taper (emerging practice, not settled):** cut
  swim and bike volume somewhat more than run volume, and taper run first — running carries the
  highest recovery/muscle-damage cost per session, so the same %-cut buys less freshness there.
- **B races** get a short 2–4 day mini-taper, not a full peak; **C races** are trained through and
  can be scheduled as a hard session the day after an easy day.
- **Expected CTL cost of a proper taper is small** — roughly 2–10%. Reassure the athlete this is
  normal and intended, not lost fitness; fatigue (ATL) drops far faster than fitness (CTL).

**Sequencing multiple A events** — the engine will periodize around however many A/B events exist,
but it has no opinion on whether they're *sensibly spaced*. Apply this judgment before adding an
event via `set_atp_event`:

- Cap **A** priority at 2–3 per season; realistically only one full peak is achievable — others
  should be raced just below ultimate freshness.
- Space A events **≥8 weeks apart** so a short rebuild block fits between them; if closer, tell the
  athlete and suggest demoting one to **B**. ≥12–15 weeks is needed to fully rebuild and re-peak from
  scratch.
- A weak or long-broken training history before the next A event may need a rebuilt Base block
  in between, not just a short Build — flag this rather than assuming the ladder alone will cover it.

---

## 6. Methodology choice — `weekly_tss` vs `target_ctl`

- **`weekly_tss`** — the athlete states a season average weekly TSS and the engine periodizes around
  it. Prefer this for athletes who **race frequently**, don't have (or don't trust) a personal-best
  CTL for the goal distance, or are earlier in their structured-training history.
- **`target_ctl`** — the athlete states the CTL wanted at each A/B event's date and the engine
  back-solves the ramp needed to reach it (bounded by `max_ramp_rate`). Prefer this when there's a
  known past CTL that produced a good result at a similar distance, or a single clear goal race.
  **Built-in reality check:** if reaching the target would require a weekly ramp above
  `max_ramp_rate`, the target is too aggressive — say so, and offer to lower the target CTL or push
  the event out rather than silently accepting an unsafe plan.

---

## 7. Sport split — why equal TSS isn't equal stress

Within a triathlon week, TSS is commonly split **~20% swim / 50% bike / 30% run** by budget (bike
gets the most because it's roughly half of race time and the lowest-impact "TSS per unit of
recovery cost"); a time-based rule of thumb for the ratio is short-course ≈1:2:1.5 and long-course
≈1:2.5–3:1.75–2 (S:B:R). Shift the split toward the athlete's **limiter** (a swim-limited athlete may
warrant 30–40% of Base-phase TSS in the pool) and toward the **event** (longer races reward bike/run
more; shorter/draft-legal races reward swim relatively more, since it's a larger time fraction).

**1 TSS point is not equally costly across sports — run > bike > swim** in recovery/tissue cost
(impact loading). Consequences worth keeping in mind when advising: a 100-TSS run needs more
recovery than a 100-TSS ride; run-side ramp should generally sit lower than bike-side ramp for the
same athlete; and a combined "all sports" PMC can overstate triathlon-specific freshness if strength
or an unusually bike-heavy week masks accumulated run fatigue — look at the sport a stagnation
complaint is actually about, not just overall CTL/TSB.

**Minimum maintenance frequency** below which a discipline stops progressing, only maintains: swim
~2×/week (3× for a weak swimmer or full-distance athlete — technique-driven, so frequency beats
duration); bike ~2–3×/week; run ~3×/week (prefer adding run *frequency* over run *duration* to build
volume with less impact per session, per Friel/Odell).

---

## 8. CTL ceilings & red flags

**CTL is an individual, relative proxy for fitness — not a target to chase.** Published ranges are
wide even at the same competitive level (e.g. one athlete rides best at CTL 100, another at 130) and
should only ever be discussed as loose orientation:

- Cyclists: age-group ~100–110, strong amateur ~120–130, pro ~140–150+.
- Triathletes (Ironman): roughly CTL 150 ≈ a ~9h finish, 120 ≈ ~10h, 80 ≈ ~12h mid-pack — again,
  individual, not prescriptive.

**"CTL hunting"** — pushing CTL up as a goal in itself rather than a byproduct of sound training — is
a recognized failure mode; don't encourage it. Watch instead for the pattern-level signals already
covered above (§3's ramp red flags, §5's taper-is-normal framing) and §9's stagnation-triage order
before concluding a plateaued CTL means "train harder."

---

## 9. Stagnation triage — order matters

When an athlete is plateauing or asks "what's the lever?", work through the factors in THIS order.
Do not reflexively jump to "train polarized" or "more intervals."

1. **Volume** (especially relative to target distance/event)
2. **Frequency** (sessions per week)
3. **Consistency** (gaps > 1 week in the last 3 months?)
4. **Specificity** (training the actual demands of the goal?)
5. **Recovery & energy** (sleep, REDs risk, iron status)
6. **Intensity distribution** — only after the above
7. **Training age** (a year-3+ VO2max plateau is NORMAL; the relevant levers shift to durability,
   efficiency, fractional utilization, body composition, race execution)

If three or more factors are flagged simultaneously, the answer is almost always base work — not
intensity sophistication.

**Polarized training is NOT a universal answer.** It is well-evidenced for trained athletes with
adequate volume. For low-volume recreational athletes (< 4 h/week cycling, < 25 km/week running,
2–3 sessions), volume and consistency dominate — recommending polarization to such an athlete is
technically defensible but practically misallocated effort.

---

## Evidence quality note

Settled and broadly convergent across sources: the 2-week/41–60%-volume/intensity-preserved taper
(Bosquet 2007; Mujika & Padilla 2003); Seiler's 80/20 polarized distribution for trained athletes;
the 3:1↔2:1 recovery cadence and 3–8 CTL/week ramp band. Flagged as one-coach practice or genuinely
contested rather than settled: exact race-day TSB targets (individual); discipline-specific taper
weighting toward sparing the run (emerging, not yet settled); block periodization's superiority
claim (Issurin's own framing, best evidenced at elite level); any hours→TSS or mileage→TSS
conversion (approximate, pace/IF-dependent — prefer the athlete's own recorded data once available
over any of the tables in §2).
