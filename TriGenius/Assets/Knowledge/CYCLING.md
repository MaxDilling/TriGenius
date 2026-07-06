# Coach-Grounding: Cycling — Sport-Specific Reference

**Purpose:** Cycling-specific reference data and pitfalls. General coaching behavior rules — data check, triage order, generic device-data caveats, communication standards, clinical-escalation rules, and the universal "ask before recommending" principle — are in the system prompt. This document covers what is specifically true for *cycling*, and should be consulted whenever cycling-specific recommendations, plans, or diagnoses are at stake.

---

## 1. Cycling-specific data to gather

Beyond the general data check (in the system prompt), pay particular attention to these cycling-specific factors:

- **Power meter setup**: none / single-sided / dual-sided / smart trainer. Single-sided meters double one leg and silently misreport when leg imbalance changes.
- **FTP currency**: when was the last structured test or all-out effort? Garmin auto-FTP without a real stimulus is extrapolation, not measurement (see §2).
- **Bike fit / position changes** in the last 8 weeks (saddle height, bar drop, aero extensions, cleat position, crank length, new shoes/pedals)
- **Road bike vs. TT bike** distribution in recent training
- **Indoor vs. outdoor** mix — power profile and HR-at-power both shift
- **Injury / discomfort history**: saddle/perineal, neck, hands, knees — these are usually fit issues, not "harden up" issues

---

## 2. Cycling-specific device pitfalls

(General device-data caveats are in the system prompt.)

### 2.1 FTP estimates — what Garmin actually reports

Garmin's auto-FTP is derived algorithmically from training history and high-intensity efforts. **It is a lagging estimate, not a measurement.**

- After a structured break or illness: Garmin FTP may stay elevated for weeks → prescribed power too high, athlete bonks
- After a single hard workout in good conditions: Garmin FTP can jump up suddenly → false high baseline
- After indoor-only training shifts to outdoor: FTP may "drop" without fitness change (different power profile, cooling, terrain)
- **Sudden FTP shifts > ±5% in < 2 weeks: treat as suspect.** Confirm with a structured effort or check whether power data quality has changed
- True FTP (60-min max sustainable) lies between ~85% and ~105% of the 20-min-based estimate — highly individual

**Before concluding "FTP has plateaued":**
- Has the athlete actually tested recently, or is Garmin extrapolating from sub-threshold rides?
- Has weight, heat, equipment, or position changed?
- Did time at-or-near FTP appear in recent training? Without the stimulus, the algorithm has nothing to update on.

### 2.2 Power vs. HR — when to trust which

- **Z5 / short intervals (≤ 3 min)**: trust power, ignore HR for real-time pacing. HR lags 30–90 s.
- **Long Z2 rides**: power is the control variable; HR drift becomes an *outcome* metric (see §2.3)
- **Heat, fatigue, illness, dehydration**: HR rises at given power → power may overstate freshness, HR correctly signals strain → cross-check both, lean on RPE
- **Indoor trainer**: HR runs higher than outdoor at matched power due to reduced cooling. Don't over-interpret.
- **Power zones tied to a stale FTP** make every workout misnamed. Re-check FTP currency before diagnosing "wrong distribution."

### 2.3 Aerobic decoupling (Pa:Hr)

The "< 5% decoupling on a long Z2 ride = aerobic base established" heuristic is **coach-derived (Friel), not RCT-validated**. The underlying physiology (cardiac drift) is well-established; the specific threshold is not.

- **Usable**: within-individual trend across weeks/months — direction of change is meaningful
- **Not usable**: comparing athletes; serving as a precise "ready to test FTP" gate
- A high-decoupling ride in heat or after poor sleep is not a base-fitness verdict — it's a confounded measurement

### 2.4 Power meter data quality — easy-to-miss confounders

- **Uncalibrated meter** → 3–10% error possible
- **Single-sided meter doubling one leg** → silent error if leg imbalance changes
- **Cold-soaked unit not zero-offset** → systematic drift
- **Low battery** → readings become erratic before complete failure
- **Pedal/crank swap mid-season** → recalibration required, otherwise data is non-comparable

**Sudden, unexplained power changes are equipment issues until proven otherwise.**

---

## 3. Stagnation triage — cycling-specific reference values

(General triage order in the system prompt: Volume → Frequency → Consistency → Specificity → Recovery → Intensity distribution → Training age.)

### Volume — cycling reference values
Coaching reference values as rough orientation (not study thresholds; evidence is mechanistic and observational, Seiler 2010 hierarchy — no RCT-derived minimums for cycling specifically):

- Sprint triathlon bike: ~3–6 h/week
- Olympic distance bike: ~5–9 h/week
- 70.3 bike target time: ~7–12 h/week
- Century / sub-3:00 100k: typically 6–10 h/week structured

These are context, not diagnosis. An athlete at 4 h/week training for a 70.3 can still progress — but "more volume" should be seriously considered before adjusting intensity distribution.

### Frequency
1–2 cycling sessions/week structurally limits adaptation. 3+ is the usual minimum for progression. For a given weekly volume, more frequent shorter sessions usually equal or beat fewer long sessions — **except** that the long ride is non-substitutable beyond Olympic distance (durability stimulus).

### Specificity
Is the athlete training the goal event's demands? 70.3 prep built entirely on Z5 intervals misses sustained sub-threshold work and durability. Olympic-distance prep with only long Z2 misses the Z4–Z5 stimulus.

### Position / equipment / aerodynamics — cycling-specific confounders
- Switched from road to TT bike? Sustainable power typically 3–8% lower in TT position
- Recent fit change (saddle height, bar drop, aero extensions)? Allow 2–4 weeks for neuromuscular adaptation
- New shoes, pedals, crank length? Confounds power-meter data
- **A "performance plateau" can be a position issue, not a training issue** — always check before diagnosing training-side stagnation

### Multi-sport interference (triathletes)
Hard run sessions immediately before bike quality? Wilson et al. 2012: concurrent training interferes dose-dependently. In triathlon, **run-induced fatigue is more often the culprit** than bike-induced — the bike is the kinder concurrent mode.

---

## 4. Polarized training & block periodization for cyclists

(The general warning that polarization is not a universal first answer is in the system prompt.)

**What the broader meta-analysis evidence says** (relevant for cycling specifically):
Recent meta-analyses (Rosenblat et al. 2019, 2024, with Seiler) suggest that for **less-trained cyclists, pyramidal is at least as good as polarized**; the polarized signal becomes clearer in well-trained / elite athletes, especially in peak/race-prep blocks. Observational data on pro cyclists shows pyramidal through most of the season, polarized only near A-races.

Cycling-specific application — as rough orientation, not study thresholds:

| Weekly cycling volume | What matters first |
|---|---|
| < 4 h | Volume, consistency, simple structure (1 quality session is plenty) |
| 4–7 h | Easy rides truly easy, 1 clear quality workout per week, build the long ride |
| 7–10 h | Pyramidal-ish structure works well; 1–2 qualities; avoid Z3 grey-zone drift |
| > 10 h | Polarized in peak blocks pays off; consider block periodization of HIT |

**Block periodization of HIT** (Rønnestad et al. 2014, 2020): concentrating 5 HIT sessions into one week, then 2–3 weeks of mostly Z2 with one HIT touch, outperforms evenly-distributed HIT in trained cyclists. **Plausibly not useful below ~7 h/week** — the maintenance weeks need enough non-HIT volume to be meaningful. For ambitious 70.3 / well-trained age-groupers, it is a legitimate option.

---

## 5. The 10% rule & progression for cyclists

(General progression principles in the system prompt: never volume + intensity in the same week; deload every 3–4 weeks; sudden single-session spikes are the strongest injury signal.)

**Cycling-specific corridors:**
- Beginner: 5–10% weekly progression
- Advanced: 10–20%
- Single long-ride progression: ≤ 20–30 min over the previous longest ride
- After illness / > 10-day break: restart at 60–70% of pre-break volume, re-progress over 2–3 weeks

**ACWR (acute:chronic workload ratio)** has been substantively critiqued (Impellizzeri et al. 2020, 2021) — do not use as a deterministic injury-risk gate. Track acute and chronic load separately, watch for step changes.

---

## 6. Volume corridors (quick reference)

### Beginner → first century (100 km / 60 mi)
- 10–16 week build
- Start: ~3–5 h/week
- End: ~7–10 h/week
- Longest ride: progress from ~1.5 h to ~4–4.5 h, peak 2 weeks before event
- ~80% Z1–Z2; tempo touches optional

### Sprint triathlon (20 km bike)
- Bike volume: 3–6 h/week sufficient
- Sessions: 1 endurance, 1 threshold or VO2max, 1 brick
- 8–12 weeks of consistent prep typically adequate

### Olympic triathlon (40 km bike)
- Bike volume: 5–9 h/week
- Sessions: 1 long endurance (1.5–2.5 h), 1 threshold (Z4) or VO2max (Z5), 1 tempo or brick, optional recovery
- 12–20 week build

### 70.3 / middle distance (90 km bike)
- Bike volume: 7–12 h/week
- Sessions: 1 long Z2 (2.5–4.5 h), 1 threshold or sweet-spot, 1 VO2max or brick, optional Z2 mid-week
- **The long-ride durability stimulus is disproportionately important** — sub-90-min long rides are insufficient
- 16–24 week build

### Long-ride share of weekly volume
- No hard rule (unlike running). 30–40% of weekly bike volume is common and tolerated. Risk is fatigue / recovery cost, not impact injury.

### Triathlon bike-volume share by distance (rough orientation)
- Sprint: 35–45% of total triathlon volume
- Olympic: 40–50%
- 70.3: 50–60%
- Ironman: 55–65%

---

## 7. Workout types — common misprescriptions

**Pitfall: Beginners get VO2max intervals before the base is built.**
→ No Z5 intervals before ~4–5 h/week of stable base volume — the adaptation depends on the foundation; otherwise the athlete just accumulates fatigue without structural support.

**Pitfall: "Sweet spot" used as the default, every week.**
- Sweet spot (~88–94% FTP, upper Z3 / lower Z4) is a time-efficient stimulus, but **overuse is the canonical grey-zone trap** — accumulates fatigue without producing the distinct adaptations of pure Z2 or pure Z5
- Use as a *complement*, not a staple. 1× per week in build is reasonable; multiple sweet-spot sessions weekly is usually wrong unless volume is high.

**Pitfall: "Tempo ride" used as a vague term.**
- Z3 (tempo) ≠ Z4 (threshold) — the coach must be specific
- Z3 has a role for sustained-effort specificity (70.3, IM), but limited per week

**Pitfall: Z5 intervals executed too hard.**
- If reps shorten or the first interval is the hardest, *time at ≥ 90% VO2max* drops — which is the actual stimulus
- 30/30s, 40/20s, and 4×4 / 4×5 min should be paced to be sustainable across the full set
- HR is a poor real-time guide for short Z5; use power and RPE

**Pitfall: "Recovery" rides ridden at Z2 upper.**
- If it's not truly easy (conversational, sub-60% HRmax, sub-60% FTP), call it Z2, not recovery
- Recovery rides have weak mechanistic evidence for accelerating recovery; their value is mostly schedule adherence and movement

**Cadence drills, single-leg drills, pedaling-technique optimization:**
- Evidence is weak / controversial (Korff et al. 2007: attempts to "smooth out" the pedal stroke generally reduce gross efficiency)
- Do not prescribe as performance interventions
- Cadence variability training (e.g., high-cadence work before a draft-legal race) is harmless and may have specificity value — but it is not a performance lever

**Strides on the bike** (high-cadence accelerations, short standing efforts): unlike running strides, no clear evidence base. Don't oversell.

---

## 8. Strength training for cyclists — not optional

If the athlete does no strength training:
- **Time-trial performance: ~2–7% improvement** in trained cyclists from 8–25 weeks of heavy strength training (Rønnestad et al. multiple RCTs; Llanos-Lagos 2025 meta-analysis)
- **Injury risk reduced ~66%** across sports (Lauersen et al. 2018) — though cycling itself has low overuse injury rates; for triathletes, this benefit mostly accrues to the run leg
- **Bone density**: road cycling does NOT promote BMD. ~⅔ of high-volume cyclists are osteopenic in lumbar spine and hip (Olmedillas et al. 2012). Heavy resistance and/or impact loading is the lever. **Particularly important for masters cyclists, women, and athletes with REDs risk factors.**

**Minimum for effect:**
- 2× per week in build phases
- 1× per week is **sufficient for maintenance** (Rønnestad et al. 2010)
- 4–10 RM loads (≥ 80% 1RM) — heavy strength outperforms high-rep "endurance strength"
- Core exercises with cycling evidence: half/full squat, leg press, deadlift, hip flexion, calf raise

**Timing:**
- Strength after the bike session on the same day, ≥ 3–6 h between (Wilson et al. 2012)
- Avoid heavy strength in the 48 h before a key bike or brick session
- Heavy strength and Z5 sessions can be combined on the same day if Z5 is in the morning and strength later

**Honest assessment:** Strength is a *moderate-effect* performance lever — real, replicated, but not transformative. Not a substitute for cycling volume or appropriate intensity distribution.

---

## 9. Recovery — cycling specifics

(General recovery principles, HRV interpretation, and clinical-escalation triggers are in the system prompt.)

**Cycling-specific markers:**
- Power at fixed HR drops; HR at fixed power rises — sustained pattern signals accumulated fatigue
- Decoupling rises at the same Z2 volume

**Cycling-specific recovery / fit issues — escalate, don't "coach through":**
- **Saddle / perineal numbness or pain** → bike fit issue, not a "harden up" issue. Persistent symptoms warrant fit review and possible medical consultation.
- **TT-position neck/shoulder load** → progress TT-bar time gradually (1–2 h initial sessions)
- **Hand numbness / ulnar nerve** → suggests excessive weight on hands; fit / hand position / glove change

---

## 10. Nutrition — cycling specifics

(General REDs, iron-deficiency, and clinical-escalation rules are in the system prompt. Note: **male endurance cyclists are an explicitly recognized at-risk population for REDs** — do not dismiss in men.)

**Carbohydrate intake during cycling (rules of thumb):**
- < 1 h: nothing required
- 1–2.5 h: 30–60 g/h
- > 2.5 h: 60–90 g/h, ideally 2:1 glucose:fructose (multiple-transportable-carbs)
- > 2.5 h with trained gut: up to 90–120 g/h (Podlogar et al. 2022; evidence less mature than ≤ 90 range — treat 90 g/h as conservative ceiling, 120 g/h as aspirational for race-trained athletes)
- **The gut must be trained** (2–4 weeks of long rides with race-level carb intake)

**Cycling's fueling advantage:** higher tolerable intake than running due to less GI jostling. **In triathlon, the bike leg is the primary fueling window for the entire race**, including the run that follows.

**Train-low / fasted Z2:**
- Some evidence for amplified mitochondrial signaling (Burke, Impey, Hawley) — moderate
- Use as a *session-level tool*, not a lifestyle — chronic underfueling slides into REDs
- Hard sessions (Z4, Z5, races) must be fueled high ("fuel for the work required")

**Daily protein:** 1.4–2.0 g/kg/day across 4–5 feedings (ISSN Joint Position Stand).

**Post-ride glycogen replenishment:** 1.0–1.2 g/kg/h CHO in the first ~4 h if the next session is within 24 h.

---

## 11. Tapering — quick reference

- Duration: 7–21 days, optimum typically **10–14 days** for Olympic/70.3, 14–21 for long course
- Volume: −40 to −60%
- **Intensity MAINTAINED** (cutting intensity is detraining, not tapering)
- Frequency: ≤ 20% reduction
- Progressive (exponentially declining) slightly better than step
- Expected performance gain: 0.5–6% (mean ~1.9%, Bosquet meta-analysis)
- Pre-taper overload (a final hard week before the taper) amplifies the gain (Mujika)

---

## 12. Triathlon specifics for the bike

### Pacing the bike for the run
- Slight negative split or even pacing; lower intensity in the first 5–10 min to recover from the swim
- Typical % FTP targets (age-group, conservative):
  - Sprint: ~85–100% FTP
  - Olympic: ~80–90% FTP
  - 70.3: ~70–80% FTP
  - Ironman: ~60–75% FTP
- **Normalized Power (NP)** is more useful than average power on rolling terrain
- TSS and IF are post-race analysis tools, **not real-time pacing tools**

### Fueling on the bike for the run leg
- 70.3: 60–90 g/h on the bike, often biased to the second half
- Ironman: 70–120 g/h on the bike (gut-trained)
- Hydration: 500–1000 ml/h, individualized to sweat rate

### Position vs. power tradeoffs
- Aerodynamics dominate at speeds > ~25 km/h — modest aero gains often save more time than equivalent fitness gains
- **However**: an aggressive position the athlete cannot sustain, or which costs > ~10–15 W of sustainable power, is net negative
- **Rule**: do not race in a position more aggressive than the athlete has practiced in 60–80% of total bike training in the final 8 weeks
- Do **not** advise on contested aero micro-optimizations (helmet choice, wheel-depth selection, etc.) — refer to a fitter or aero specialist

### TT bike vs. road bike
- TT bike: ~10–20% drag reduction at racing speeds in good position
- Sustainable power typically 3–8% lower in TT position (sometimes more)
- TT bike makes sense for non-drafting Olympic+ on flat-to-rolling courses **if** the athlete has trained the position
- Draft-legal racing: road bike only
- Very hilly courses (Lanzarote, Nice profiles): TT advantage shrinks; clip-on aero bars on a road bike sometimes faster

### Brick workouts
- 1 bike→run brick per week in build phases; sometimes 2 in 70.3 / IM peak blocks
- Run portion: short (10–20 min) if the goal is transition adaptation; longer (30–60+ min) for specificity
- **Common mistake:** every long bike followed by a long run — multiplies fatigue and run injury risk. Most bricks should have a *short* run.

### Concurrent training & interference
- Bike + run interferes less than run + heavy strength (Wilson et al. 2012)
- Run is the more biomechanically demanding mode and typically the bottleneck for total triathlon load
- **If stagnation, the run is more often the culprit than the bike** (higher injury / recovery cost)